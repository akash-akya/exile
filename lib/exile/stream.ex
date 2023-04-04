defmodule Exile.Stream do
  @moduledoc """
  Defines a `Exile.Stream` struct returned by `Exile.stream!/2`.
  """

  alias Exile.Process
  alias Exile.Process.Error

  require Logger

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

  defstruct [:process, :stream_opts, :writer_task]

  @typedoc "Struct members are private, do not depend on them"
  @type t :: %__MODULE__{process: Process.t(), stream_opts: map, writer_task: Task.t()}

  @doc false
  @spec __build__(nonempty_list(String.t()), keyword()) :: t()
  def __build__(cmd_with_args, opts) do
    {stream_opts, process_opts} =
      Keyword.split(opts, [:exit_timeout, :max_chunk_size, :input, :enable_stderr, :ignore_epipe])

    case normalize_stream_opts(stream_opts) do
      {:ok, stream_opts} ->
        process_opts = Keyword.put(process_opts, :enable_stderr, stream_opts[:enable_stderr])
        {:ok, process} = Process.start_link(cmd_with_args, process_opts)

        writer_task =
          start_input_streamer(
            %Sink{process: process, ignore_epipe: stream_opts[:ignore_epipe]},
            stream_opts.input
          )

        %Exile.Stream{process: process, stream_opts: stream_opts, writer_task: writer_task}

      {:error, error} ->
        raise ArgumentError, message: error
    end
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

  defimpl Enumerable do
    def reduce(arg, acc, fun) do
      %{
        process: process,
        stream_opts:
          %{
            enable_stderr: enable_stderr,
            ignore_epipe: ignore_epipe
          } = stream_opts,
        writer_task: writer_task
      } = arg

      start_fun = fn -> :premature_exit end

      next_fun = fn :premature_exit ->
        case Process.read_any(process, stream_opts.max_chunk_size) do
          :eof ->
            {:halt, :normal_exit}

          {:ok, {:stdout, x}} when enable_stderr == false ->
            {[IO.iodata_to_binary(x)], :premature_exit}

          {:ok, {stream, x}} when enable_stderr == true ->
            {[{stream, IO.iodata_to_binary(x)}], :premature_exit}

          {:error, errno} ->
            raise Error, "failed to read from the external process. errno: #{inspect(errno)}"
        end
      end

      after_fun = fn exit_type ->
        result = Process.await_exit(process, stream_opts.exit_timeout)
        writer_task_status = Task.await(writer_task)

        case {exit_type, result, writer_task_status} do
          # if reader exit early and there is a pending write
          {:premature_exit, {:ok, _status}, {:error, :epipe}} when ignore_epipe ->
            :ok

          # if reader exit early and there is no pending write or if
          # there is no writer
          {:premature_exit, {:ok, _status}, :ok} when ignore_epipe ->
            :ok

          # if we get epipe from writer then raise that error, and ignore exit status
          {:premature_exit, {:ok, _status}, {:error, :epipe}} when ignore_epipe == false ->
            raise Error, "abnormal command exit, received EPIPE while writing to stdin"

          # Normal exit success case
          {_, {:ok, 0}, _} ->
            :ok

          {:normal_exit, {:ok, error}, _} ->
            raise Error, "command exited with status: #{inspect(error)}"
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

      timeout when is_integer(timeout) and timeout > 0 ->
        {:ok, timeout}

      _ ->
        {:error, ":exit_timeout must be either :infinity or an integer"}
    end
  end

  defp normalize_enable_stderr(enable_stderr) do
    case enable_stderr do
      nil ->
        {:ok, false}

      enable_stderr when is_boolean(enable_stderr) ->
        {:ok, enable_stderr}

      _ ->
        {:error, ":enable_stderr must be a boolean"}
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

  defp normalize_stream_opts(opts) do
    with {:ok, input} <- normalize_input(opts[:input]),
         {:ok, exit_timeout} <- normalize_exit_timeout(opts[:exit_timeout]),
         {:ok, max_chunk_size} <- normalize_max_chunk_size(opts[:max_chunk_size]),
         {:ok, enable_stderr} <- normalize_enable_stderr(opts[:enable_stderr]),
         {:ok, ignore_epipe} <- normalize_ignore_epipe(opts[:ignore_epipe]) do
      {:ok,
       %{
         input: input,
         exit_timeout: exit_timeout,
         max_chunk_size: max_chunk_size,
         enable_stderr: enable_stderr,
         ignore_epipe: ignore_epipe
       }}
    end
  end
end
