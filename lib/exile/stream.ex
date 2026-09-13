defmodule Exile.Stream do
  @moduledoc """
  Defines a `Exile.Stream` struct returned by `Exile.stream!/2`.
  """

  alias Exile.Process
  alias Exile.Process.Error

  require Logger

  defmodule AbnormalExit do
    defexception [:message, :exit_status]

    @impl true
    def exception(:epipe) do
      msg = "program exited due to :epipe error"
      %__MODULE__{message: msg, exit_status: :epipe}
    end

    def exception(exit_status) do
      msg = "program exited with exit status: #{exit_status}"
      %__MODULE__{message: msg, exit_status: exit_status}
    end
  end

  defmodule Sink do
    @moduledoc false

    @type t :: %__MODULE__{process: Process.t(), ignore_epipe: boolean}

    defstruct [:process, :ignore_epipe]

    defimpl Collectable do
      def into(%{process: process}) do
        collector_fun = fn
          :ok, {:cont, x} ->
            case Process.write(process, x) do
              {:error, :epipe} ->
                # there is no other way to stop a Collectable than to
                # raise error, we catch this error and return `{:error, :epipe}`
                raise Error, "epipe"

              :ok ->
                :ok
            end

          acc, :done ->
            acc

          acc, :halt ->
            acc
        end

        {:ok, collector_fun}
      end
    end
  end

  defstruct [:stream_opts, :process_opts, :cmd_with_args]

  @typedoc "Struct members are private, do not depend on them"
  @type t :: %__MODULE__{
          stream_opts: map(),
          process_opts: keyword(),
          cmd_with_args: [String.t()]
        }

  @stream_opts [
    :exit_timeout,
    :cancel_timeout,
    :max_chunk_size,
    :input,
    :stderr,
    :ignore_epipe,
    :stream_exit_status
  ]

  @doc false
  @spec __build__(nonempty_list(String.t()), keyword()) :: t()
  def __build__(cmd_with_args, opts) do
    {stream_opts, process_opts} = Keyword.split(opts, @stream_opts)

    case normalize_stream_opts(stream_opts) do
      {:ok, stream_opts} ->
        %Exile.Stream{
          stream_opts: stream_opts,
          process_opts: process_opts,
          cmd_with_args: cmd_with_args
        }

      {:error, error} ->
        raise ArgumentError, message: error
    end
  end

  defimpl Enumerable do
    # Logger used :warn before Elixir 1.11.
    if macro_exported?(Logger, :warning, 2) do
      @warning_level :warning
    else
      @warning_level :warn
    end

    def reduce(arg, acc, fun) do
      state = start_process(arg)
      reduce_stream(state, acc, fun)
    end

    def count(_stream) do
      {:error, __MODULE__}
    end

    def member?(_stream, _term) do
      {:error, __MODULE__}
    end

    def slice(_stream) do
      {:error, __MODULE__}
    end

    defp reduce_stream(state, step, fun) do
      case step do
        {:suspend, acc} ->
          {:suspended, acc, &reduce_stream(state, &1, fun)}

        {_operation, acc} when state == :exited ->
          {:halted, acc}

        {:halt, acc} ->
          exit_result = await_exit(state, :halt)
          check_exit_status(exit_result)
          {:halted, acc}

        {:cont, acc} ->
          continue_stream(state, acc, fun)
      end
    end

    defp continue_stream(state, acc, fun) do
      next_step =
        try do
          case read_next(state) do
            :eof -> :eof
            {:ok, element} -> fun.(element, acc)
          end
        catch
          kind, reason ->
            stacktrace = __STACKTRACE__
            cleanup_safely(fn -> await_exit(state, :cleanup) end)
            :erlang.raise(kind, reason, stacktrace)
        end

      case next_step do
        :eof ->
          exit_result = await_exit(state, :eof)

          if state.stream_opts.stream_exit_status do
            next_acc = fun.(exit_result, acc)
            reduce_stream(:exited, next_acc, fun)
          else
            check_exit_status(exit_result)
            {:halted, acc}
          end

        _ ->
          reduce_stream(state, next_step, fun)
      end
    end

    defp read_next(state) do
      %{process: process, stream_opts: stream_opts} = state

      case Process.read_any(process, stream_opts.max_chunk_size) do
        :eof ->
          :eof

        {:ok, {io_stream, data}} when stream_opts.stderr == :consume ->
          {:ok, {io_stream, IO.iodata_to_binary(data)}}

        {:ok, {:stdout, data}} ->
          {:ok, IO.iodata_to_binary(data)}

        {:error, {:input, {kind, reason, stacktrace}}} ->
          :erlang.raise(kind, reason, stacktrace)

        {:error, errno} ->
          raise Error, "failed to read from the external process. errno: #{inspect(errno)}"
      end
    end

    defp cleanup_safely(fun) do
      fun.()
    catch
      kind, reason ->
        Logger.log(
          @warning_level,
          "Exile stream cleanup failed: " <> Exception.format(kind, reason, __STACKTRACE__)
        )
    end

    defp check_exit_status(result) do
      case result do
        {:exit, {:status, 0}} -> :ok
        {:exit, {:status, exit_status}} -> raise AbnormalExit, exit_status
        {:exit, :epipe} -> raise AbnormalExit, :epipe
      end
    end

    defp start_process(stream) do
      stream_opts = stream.stream_opts
      process_opts = Keyword.put(stream.process_opts, :stderr, stream_opts[:stderr])
      {:ok, process} = Process.start_link(stream.cmd_with_args, process_opts)
      sink = %Sink{process: process, ignore_epipe: stream_opts[:ignore_epipe]}

      writer_task =
        Task.async(fn -> stream_input(sink, stream_opts.input, stream_opts.cancel_timeout) end)

      %{process: process, stream_opts: stream_opts, writer_task: writer_task}
    end

    defp stream_input(sink, input, cancel_timeout) do
      process = sink.process

      result =
        case input do
          :no_input ->
            :ok

          {:enumerable, enum} ->
            Process.change_pipe_owner(process, :stdin, self())
            Enum.into(enum, sink)

          {:collectable, func} ->
            Process.change_pipe_owner(process, :stdin, self())
            func.(sink)
        end

      {:ok, result}
    catch
      :error, %Error{message: "epipe"} ->
        {:error, :epipe}

      kind, reason ->
        stacktrace = __STACKTRACE__
        Process.input_failed(sink.process, {kind, reason, stacktrace}, cancel_timeout)
        {:input_error, kind, reason, stacktrace}
    end

    defp input_result(result, exit_state) do
      case result do
        {:ok, value} ->
          value

        {:input_error, _kind, _reason, _stacktrace} when exit_state == :cleanup ->
          # Preserve the original failure during cleanup.
          :cancelled

        {:input_error, kind, reason, stacktrace} ->
          :erlang.raise(kind, reason, stacktrace)

        _ ->
          result
      end
    end

    defp await_exit(state, exit_state) do
      %{process: process, stream_opts: opts, writer_task: writer_task} = state

      try do
        case exit_state do
          :eof ->
            {:ok, exit_status} = Process.await_exit(process, opts.exit_timeout)
            writer_result = Task.await(writer_task)
            input_result(writer_result, :eof)
            {:exit, {:status, exit_status}}

          exit_state when exit_state in [:halt, :cleanup] ->
            cancel_stream(state, exit_state)
        end
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          cleanup_safely(fn -> Task.shutdown(writer_task, :brutal_kill) end)
          # Let the existing watcher reap the command if awaiting it failed.
          Elixir.Process.unlink(process.pid)
          Elixir.Process.exit(process.pid, :kill)
          Elixir.Process.demonitor(process.monitor_ref, [:flush])
          :erlang.raise(kind, reason, stacktrace)
      end
    end

    defp cancel_stream(state, exit_state) do
      %{process: process, stream_opts: opts, writer_task: writer_task} = state
      {:ok, exit_status} = Process.await_exit(process, opts.cancel_timeout)
      writer_result = await_writer(writer_task, opts.cancel_timeout)
      writer_status = input_result(writer_result, exit_state)

      case {writer_status, opts.ignore_epipe} do
        {status, true} when status in [:ok, :cancelled, {:error, :epipe}] ->
          {:exit, {:status, 0}}

        {{:error, :epipe}, false} ->
          {:exit, :epipe}

        _ ->
          {:exit, {:status, exit_status}}
      end
    end

    defp await_writer(writer_task, timeout) do
      result =
        case Task.yield(writer_task, timeout) do
          nil -> Task.shutdown(writer_task, :brutal_kill)
          reply -> reply
        end

      case result do
        {:ok, status} -> status
        nil -> :cancelled
        {:exit, reason} -> exit({reason, {Task, :await, [writer_task, timeout]}})
      end
    end
  end

  @spec normalize_input(term) ::
          {:ok, :no_input} | {:ok, {:enumerable, term}} | {:ok, {:collectable, function}}
  defp normalize_input(term) do
    cond do
      is_nil(term) ->
        {:ok, :no_input}

      !is_function(term, 1) && Enumerable.impl_for(term) ->
        {:ok, {:enumerable, term}}

      is_function(term, 1) ->
        {:ok, {:collectable, term}}

      true ->
        {:error, "`:input` must be either Enumerable or a function which accepts collectable"}
    end
  end

  defp normalize_max_chunk_size(max_chunk_size) do
    case max_chunk_size do
      nil ->
        {:ok, 65_536}

      max_chunk_size when is_integer(max_chunk_size) and max_chunk_size > 0 ->
        {:ok, max_chunk_size}

      _ ->
        {:error, ":max_chunk_size must be a positive integer"}
    end
  end

  defp normalize_timeout(timeout, default, option) do
    case timeout do
      nil ->
        {:ok, default}

      :infinity ->
        {:ok, :infinity}

      timeout when is_integer(timeout) and timeout > 0 ->
        {:ok, timeout}

      _ ->
        {:error, ":#{option} must be either :infinity or an integer"}
    end
  end

  defp normalize_stderr(stderr) do
    case stderr do
      nil ->
        {:ok, :console}

      stderr when stderr in [:console, :redirect_to_stdout, :disable, :consume] ->
        {:ok, stderr}

      _ ->
        {:error,
         ":stderr must be an atom and one of :console, :redirect_to_stdout, :disable, :consume"}
    end
  end

  defp normalize_ignore_epipe(ignore_epipe) do
    case ignore_epipe do
      nil ->
        {:ok, false}

      ignore_epipe when is_boolean(ignore_epipe) ->
        {:ok, ignore_epipe}

      _ ->
        {:error, ":ignore_epipe must be a boolean"}
    end
  end

  defp normalize_stream_exit_status(stream_exit_status) do
    case stream_exit_status do
      nil ->
        {:ok, false}

      stream_exit_status when is_boolean(stream_exit_status) ->
        {:ok, stream_exit_status}

      _ ->
        {:error, ":stream_exit_status must be a boolean"}
    end
  end

  defp normalize_stream_opts(opts) do
    with {:ok, input} <- normalize_input(opts[:input]),
         {:ok, exit_timeout} <- normalize_timeout(opts[:exit_timeout], 5000, :exit_timeout),
         {:ok, cancel_timeout} <- normalize_timeout(opts[:cancel_timeout], 1000, :cancel_timeout),
         {:ok, max_chunk_size} <- normalize_max_chunk_size(opts[:max_chunk_size]),
         {:ok, stderr} <- normalize_stderr(opts[:stderr]),
         {:ok, ignore_epipe} <- normalize_ignore_epipe(opts[:ignore_epipe]),
         {:ok, stream_exit_status} <- normalize_stream_exit_status(opts[:stream_exit_status]) do
      {:ok,
       %{
         input: input,
         exit_timeout: exit_timeout,
         cancel_timeout: cancel_timeout,
         max_chunk_size: max_chunk_size,
         stderr: stderr,
         ignore_epipe: ignore_epipe,
         stream_exit_status: stream_exit_status
       }}
    end
  end
end
