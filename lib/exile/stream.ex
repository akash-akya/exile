defmodule Exile.Stream do
  @moduledoc """
  Defines a `Exile.Stream` struct returned by `Exile.stream!/3`.
  """

  alias Exile.Process

  defmodule Sink do
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
    {stream_opts, process_opts} = Keyword.split(opts, [:exit_timeout, :chunk_size, :input])

    with {:ok, stream_opts} <- normalize_stream_opts(stream_opts) do
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
    def reduce(%{process: process, stream_opts: stream_opts}, acc, fun) do
      start_fun = fn -> :ok end

      next_fun = fn :ok ->
        case Process.read(process, stream_opts.chunk_size) do
          {:eof, []} ->
            {:halt, :normal}

          {:eof, x} ->
            # multiple reads on closed pipe always returns :eof
            {[IO.iodata_to_binary(x)], :ok}

          {:ok, x} ->
            {[IO.iodata_to_binary(x)], :ok}

          {:error, errno} ->
            raise "Failed to read from the process. errno: #{errno}"
        end
      end

      after_fun = fn exit_type ->
        try do
          # always close stdin before stoping to give the command chance to exit properly
          Process.close_stdin(process)
          result = Process.await_exit(process, stream_opts.exit_timeout)

          case {exit_type, result} do
            {_, :timeout} ->
              Process.kill(process, :sigkill)
              raise "command fail to exit within timeout: #{stream_opts[:exit_timeout]}"

            {:normal, {:ok, {:exit, 0}}} ->
              :ok

            {:normal, {:ok, error}} ->
              raise "command exited with status: #{inspect(error)}"

            {exit_type, error} ->
              Process.kill(process, :sigkill)
              raise "command exited with exit_type: #{exit_type}, error: #{inspect(error)}"
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

  defp normalize_chunk_size(nil), do: {:ok, 65536}
  defp normalize_chunk_size(:no_buffering), do: {:ok, :no_buffering}

  defp normalize_chunk_size(chunk_size) do
    if is_integer(chunk_size) and chunk_size > 0,
      do: {:ok, chunk_size},
      else: {:error, ":exit_timeout must be either :infinity or a positive integer"}
  end

  defp normalize_exit_timeout(term) when term in [nil, :infinity], do: {:ok, :infinity}

  defp normalize_exit_timeout(term) do
    if is_integer(term),
      do: {:ok, term},
      else: {:error, ":exit_timeout must be either :infinity or an integer"}
  end

  defp normalize_stream_opts(opts) when is_list(opts) do
    with {:ok, input} <- normalize_input(opts[:input]),
         {:ok, exit_timeout} <- normalize_exit_timeout(opts[:exit_timeout]),
         {:ok, chunk_size} <- normalize_chunk_size(opts[:chunk_size]) do
      {:ok, %{input: input, exit_timeout: exit_timeout, chunk_size: chunk_size}}
    end
  end

  defp normalize_stream_opts(_), do: {:error, "stream_opts must be a keyword list"}
end
