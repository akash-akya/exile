defmodule Exile.Stream do
  @moduledoc """
  Defines a `Exile.Stream` struct returned by `Exile.stream!/2`.
  """

  alias Exile.Process
  alias Exile.Process.Error

  defmodule Sink do
    @moduledoc false

    defstruct [:process]

    defimpl Collectable do
      def into(%{process: process} = stream) do
        collector_fun = fn
          :ok, {:cont, x} ->
            :ok = Process.write(process, x)

          :ok, :done ->
            :ok = Process.close_stdin(process)
            stream

          :ok, :halt ->
            :ok = Process.close_stdin(process)
        end

        {:ok, collector_fun}
      end
    end
  end

  defstruct [:process, :stream_opts]

  @type t :: %__MODULE__{}

  @doc false
  def __build__(cmd_with_args, opts) do
    {stream_opts, process_opts} =
      Keyword.split(opts, [:exit_timeout, :max_chunk_size, :input, :use_stderr])

    with {:ok, stream_opts} <- normalize_stream_opts(stream_opts) do
      process_opts = Keyword.put(process_opts, :use_stderr, stream_opts[:use_stderr])
      {:ok, process} = Process.start_link(cmd_with_args, process_opts)
      start_input_streamer(%Sink{process: process}, stream_opts.input)
      %Exile.Stream{process: process, stream_opts: stream_opts}
    else
      {:error, error} -> raise ArgumentError, message: error
    end
  end

  @doc false
  defp start_input_streamer(sink, input) do
    case input do
      :no_input ->
        :ok

      {:enumerable, enum} ->
        spawn_link(fn ->
          Enum.into(enum, sink)
        end)

      {:collectable, func} ->
        spawn_link(fn ->
          func.(sink)
        end)
    end
  end

  defimpl Enumerable do
    def reduce(arg, acc, fun) do
      %{process: process, stream_opts: %{use_stderr: use_stderr} = stream_opts} = arg

      start_fun = fn -> :normal end

      next_fun = fn :normal ->
        case Process.read_any(process, stream_opts.max_chunk_size) do
          :eof ->
            {:halt, :normal}

          {:ok, {:stdout, x}} when use_stderr == false ->
            {[IO.iodata_to_binary(x)], :normal}

          {:ok, {stream, x}} when use_stderr == true ->
            {[{stream, IO.iodata_to_binary(x)}], :normal}

          {:error, errno} ->
            raise Error, "Failed to read from the external process. errno: #{errno}"
        end
      end

      after_fun = fn exit_type ->
        try do
          # always close stdin before stopping to give the command chance to exit properly
          Process.close_stdin(process)
          result = Process.await_exit(process, stream_opts.exit_timeout)

          case {exit_type, result} do
            {_, :timeout} ->
              Process.kill(process, :sigkill)
              raise Error, "command fail to exit within timeout: #{stream_opts[:exit_timeout]}"

            {:normal, {:ok, {:exit, 0}}} ->
              :ok

            {:normal, {:ok, error}} ->
              raise Error, "command exited with status: #{inspect(error)}"

            {exit_type, error} ->
              Process.kill(process, :sigkill)
              raise Error, "command exited with exit_type: #{exit_type}, error: #{inspect(error)}"
          end
        after
          Process.stop(process)
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

  defp normalize_input(term) do
    cond do
      is_nil(term) ->
        {:ok, :no_input}

      !is_function(term) && Enumerable.impl_for(term) ->
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
        {:ok, 65536}

      max_chunk_size when is_integer(max_chunk_size) and max_chunk_size > 0 ->
        {:ok, max_chunk_size}

      _ ->
        {:error, ":max_chunk_size must be a positive integer"}
    end
  end

  defp normalize_exit_timeout(timeout) do
    case timeout do
      nil ->
        {:ok, :infinity}

      timeout when is_integer(timeout) and timeout > 0 ->
        {:ok, timeout}

      _ ->
        {:error, ":exit_timeout must be either :infinity or an integer"}
    end
  end

  defp normalize_use_stderr(use_stderr) do
    case use_stderr do
      nil ->
        {:ok, false}

      use_stderr when is_boolean(use_stderr) ->
        {:ok, use_stderr}

      _ ->
        {:error, ":use_stderr must be a boolean"}
    end
  end

  defp normalize_stream_opts(opts) when is_list(opts) do
    with {:ok, input} <- normalize_input(opts[:input]),
         {:ok, exit_timeout} <- normalize_exit_timeout(opts[:exit_timeout]),
         {:ok, max_chunk_size} <- normalize_max_chunk_size(opts[:max_chunk_size]),
         {:ok, use_stderr} <- normalize_use_stderr(opts[:use_stderr]) do
      {:ok,
       %{
         input: input,
         exit_timeout: exit_timeout,
         max_chunk_size: max_chunk_size,
         use_stderr: use_stderr
       }}
    end
  end

  defp normalize_stream_opts(_), do: {:error, "stream_opts must be a keyword list"}
end
