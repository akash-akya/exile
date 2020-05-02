defmodule Exile.Stream do
  alias Exile.Process

  defstruct [:proc_server]

  @type t :: %__MODULE__{}

  @doc false
  def __build__(cmd, args) do
    {:ok, proc} = Process.start_link(cmd, args)
    %Exile.Stream{proc_server: proc}
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
    @chunk_size 65535

    def reduce(%{proc_server: proc}, acc, fun) do
      start_fun = fn -> :ok end

      next_fun = fn :ok ->
        case Process.read(proc, @chunk_size) do
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

          result = Process.await_exit(proc)

          if exit_type == :normal_exit do
            case result do
              {:ok, 0} -> :ok
              {:ok, status} -> raise "command exited with status: #{status}"
            end
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
