defmodule Exile.Stream do
  @moduledoc """
   Defines a `Exile.Stream` struct returned by `Exile.stream!/3`.
  """

  alias Exile.Process

  defstruct [:proc_server, :stream_opts]

  @default_opts %{exit_timeout: :infinity, chunk_size: 65535}

  @type t :: %__MODULE__{}

  @doc false
  def __build__(cmd, args, opts) do
    opts = Map.merge(@default_opts, opts)
    {stream_opts, proc_opts} = Map.split(opts, [:exit_timeout, :chunk_size])
    {:ok, proc} = Process.start_link(cmd, args, proc_opts)
    %Exile.Stream{proc_server: proc, stream_opts: stream_opts}
  end

  defimpl Collectable do
    def into(%{proc_server: proc} = stream) do
      collector_fun = fn
        :ok, {:cont, x} ->
          :ok = Process.write(proc, x)

        :ok, :done ->
          :ok = Process.close_stdin(proc)
          stream

        :ok, :halt ->
          :ok = Process.close_stdin(proc)
      end

      {:ok, collector_fun}
    end
  end

  defimpl Enumerable do
    def reduce(%{proc_server: proc, stream_opts: stream_opts}, acc, fun) do
      start_fun = fn -> :ok end

      next_fun = fn :ok ->
        case Process.read(proc, stream_opts.chunk_size) do
          {:eof, []} ->
            {:halt, :normal}

          {:eof, x} ->
            # multiple reads on closed pipe always returns :eof
            {[x], :ok}

          {:ok, x} ->
            {[x], :ok}

          {:error, errno} ->
            raise "Failed to read from the process. errno: #{errno}"
        end
      end

      after_fun = fn exit_type ->
        try do
          # always close stdin before stoping to give the command chance to exit properly
          Process.close_stdin(proc)
          result = Process.await_exit(proc, stream_opts.exit_timeout)

          case {exit_type, result} do
            {_, :timeout} ->
              Process.kill(proc, :sigkill)
              raise "command fail to exit within timeout: #{stream_opts.exit_timeout}"

            {:normal, {:ok, 0}} ->
              :ok

            {:normal, {:ok, exit_status}} ->
              raise "command exited with status: #{exit_status}"

            {_, error} ->
              Process.kill(proc, :sigkill)
              raise "command exited with error: #{inspect(error)}"
          end
        after
          Process.stop(proc)
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
end
