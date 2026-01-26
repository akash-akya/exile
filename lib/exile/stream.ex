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

              {:error, errno} ->
                # handle other error codes (e.g., EBADF, etc)
                raise Error, "write error errno: #{inspect(errno)}"

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
    # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
    def reduce(arg, acc, fun) do
      start_fun = fn ->
        state = start_process(arg)
        {state, :running}
      end

      next_fun = fn
        {state, :exited} ->
          {:halt, {state, :exited}}

        {state, exit_state} ->
          %{
            process: process,
            stream_opts: %{
              stderr: stderr,
              stream_exit_status: stream_exit_status,
              max_chunk_size: max_chunk_size
            }
          } = state

          case Process.read_any(process, max_chunk_size) do
            :eof when stream_exit_status == false ->
              {:halt, {state, :eof}}

            :eof when stream_exit_status == true ->
              elem = [await_exit(state, :eof)]
              {elem, {state, :exited}}

            {:ok, {:stdout, x}} when stderr != :consume ->
              elem = [IO.iodata_to_binary(x)]
              {elem, {state, exit_state}}

            {:ok, {io_stream, x}} when stderr == :consume ->
              elem = [{io_stream, IO.iodata_to_binary(x)}]
              {elem, {state, exit_state}}

            {:error, errno} ->
              raise Error, "failed to read from the external process. errno: #{inspect(errno)}"
          end
      end

      after_fun = fn
        {_state, :exited} ->
          :ok

        {state, exit_state} ->
          case await_exit(state, exit_state) do
            {:exit, {:status, 0}} ->
              :ok

            {:exit, {:status, exit_status}} ->
              raise AbnormalExit, exit_status

            {:exit, :epipe} ->
              raise AbnormalExit, :epipe
          end
      end

      Stream.resource(start_fun, next_fun, after_fun).(acc, fun)
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

    defp start_process(%Exile.Stream{
           process_opts: process_opts,
           stream_opts: stream_opts,
           cmd_with_args: cmd_with_args
         }) do
      process_opts = Keyword.put(process_opts, :stderr, stream_opts[:stderr])
      {:ok, process} = Process.start_link(cmd_with_args, process_opts)
      sink = %Sink{process: process, ignore_epipe: stream_opts[:ignore_epipe]}
      writer_task = start_input_streamer(sink, stream_opts.input)

      %{process: process, stream_opts: stream_opts, writer_task: writer_task}
    end

    @doc false
    @spec start_input_streamer(term, term) :: Task.t()
    defp start_input_streamer(%Sink{process: process} = sink, input) do
      case input do
        :no_input ->
          # use `Task.completed(:ok)` when bumping min Elixir requirement
          Task.async(fn -> :ok end)

        {:enumerable, enum} ->
          Task.async(fn ->
            Process.change_pipe_owner(process, :stdin, self())

            try do
              Enum.into(enum, sink)
            rescue
              Error ->
                {:error, :epipe}
            end
          end)

        {:collectable, func} ->
          Task.async(fn ->
            Process.change_pipe_owner(process, :stdin, self())

            try do
              func.(sink)
            rescue
              Error ->
                {:error, :epipe}
            end
          end)
      end
    end

    defp await_exit(state, exit_state) do
      %{
        process: process,
        stream_opts: %{ignore_epipe: ignore_epipe, exit_timeout: exit_timeout},
        writer_task: writer_task
      } = state

      result = Process.await_exit(process, exit_timeout)
      writer_task_status = Task.await(writer_task)

      case {exit_state, result, writer_task_status} do
        # if reader exit early and there is a pending write
        {:running, {:ok, _status}, {:error, :epipe}} when ignore_epipe ->
          {:exit, {:status, 0}}

        # if reader exit early and there is no pending write or if
        # there is no writer
        {:running, {:ok, _status}, :ok} when ignore_epipe ->
          {:exit, {:status, 0}}

        # if we get epipe from writer then raise that error, and ignore exit status
        {:running, {:ok, _status}, {:error, :epipe}} when ignore_epipe == false ->
          {:exit, :epipe}

        # Normal exit success case
        {_, {:ok, 0}, _} ->
          {:exit, {:status, 0}}

        {:eof, {:ok, exit_status}, _} ->
          {:exit, {:status, exit_status}}
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

  defp normalize_exit_timeout(timeout) do
    case timeout do
      nil ->
        {:ok, 5000}

      :infinity ->
        {:ok, :infinity}

      timeout when is_integer(timeout) and timeout > 0 ->
        {:ok, timeout}

      _ ->
        {:error, ":exit_timeout must be either :infinity or an integer"}
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
         {:ok, exit_timeout} <- normalize_exit_timeout(opts[:exit_timeout]),
         {:ok, max_chunk_size} <- normalize_max_chunk_size(opts[:max_chunk_size]),
         {:ok, stderr} <- normalize_stderr(opts[:stderr]),
         {:ok, ignore_epipe} <- normalize_ignore_epipe(opts[:ignore_epipe]),
         {:ok, stream_exit_status} <- normalize_stream_exit_status(opts[:stream_exit_status]) do
      {:ok,
       %{
         input: input,
         exit_timeout: exit_timeout,
         max_chunk_size: max_chunk_size,
         stderr: stderr,
         ignore_epipe: ignore_epipe,
         stream_exit_status: stream_exit_status
       }}
    end
  end
end
