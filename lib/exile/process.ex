defmodule Exile.Process do
  alias Exile.ProcessHelper
  require Logger
  use GenServer

  def start_link(cmd, args) do
    GenServer.start(__MODULE__, %{cmd: cmd, args: args})
  end

  def close_stdin(process) do
    GenServer.call(process, :close_stdin, :infinity)
  end

  def write(process, binary) do
    GenServer.call(process, {:write, binary}, :infinity)
  end

  def read(process, bytes) do
    GenServer.call(process, {:read, bytes}, :infinity)
  end

  def os_pid(process) do
    GenServer.call(process, :os_pid, :infinity)
  end

  def kill(process, signal) when signal in [:sigkill, :sigterm] do
    GenServer.call(process, {:kill, signal}, :infinity)
  end

  def await_exit(process) do
    GenServer.call(process, :await_exit, :infinity)
  end

  ## Server

  def init(%{cmd: cmd, args: args}) do
    path = :os.find_executable(to_charlist(cmd))

    unless path do
      raise "Command not found: #{cmd}"
    end

    {:ok, %{cmd: path, args: args, read_acc: [], errno: nil}, {:continue, nil}}
  end

  def handle_continue(nil, state) do
    exec_args = Enum.map(state.args, &to_charlist/1)

    case ProcessHelper.exec_proc([state.cmd | exec_args]) do
      {:ok, {pid, stdin, stdout}} ->
        start_watcher(pid, stdin)
        state = Map.merge(state, %{pid: pid, stdin: stdin, stdout: stdout})
        {:noreply, state}

      {:error, errno} ->
        raise "Failed to start command: #{state.cmd}, errno: #{errno}"
    end
  end

  def handle_call({:write, binary}, from, state), do: do_write(state, from, binary)

  def handle_call({:read, bytes}, from, state), do: do_read(state, from, bytes)

  def handle_call(:os_pid, _from, state), do: {:reply, state.pid, state}

  def handle_call(:close_stdin, _from, state) do
    case ProcessHelper.close_pipe(state.stdin) do
      :ok ->
        {:reply, :ok, state}

      {:error, errno} ->
        {:reply, {:error, errno}, %{state | errno: errno}}
    end
  end

  def handle_call(:await_exit, from, state), do: do_await_exit(state, from)

  def handle_info({:read, bytes, from}, state), do: do_read(state, from, bytes)
  def handle_info({:write, binary, from}, state), do: do_write(state, from, binary)
  def handle_info({:await_exit, from}, state), do: do_await_exit(state, from)

  defp do_write(state, from, binary) do
    case ProcessHelper.write_proc(state.stdin, binary) do
      {:ok, bytes} ->
        if bytes < IO.iodata_length(binary) do
          binary = IO.iodata_to_binary(binary)
          binary = binary_part(binary, bytes, IO.iodata_length(binary))
          Process.send_after(self(), {:write, binary, from}, 100)
        else
          GenServer.reply(from, :ok)
        end

        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(from, {:error, errno})
        {:noreply, %{state | errno: errno}}
    end
  end

  defp do_read(state, from, bytes) do
    case ProcessHelper.read_proc(state.stdout, bytes) do
      {:ok, <<>>} ->
        GenServer.reply(from, {:eof, state.read_acc})
        {:noreply, %{state | read_acc: []}}

      {:ok, binary} ->
        if IO.iodata_length(binary) < bytes do
          Process.send_after(self(), {:read, bytes - IO.iodata_length(binary), from}, 100)
          {:noreply, %{state | read_acc: [state.read_acc | binary]}}
        else
          GenServer.reply(from, {:ok, [state.read_acc | binary]})
          {:noreply, %{state | read_acc: []}}
        end

      # EAGAIN
      {:error, 35} ->
        Process.send_after(self(), {:read, bytes, from}, 100)
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(from, {:error, errno})
        {:noreply, %{state | errno: errno}}
    end
  end

  defp do_await_exit(%{pid: pid} = state, from) do
    case ProcessHelper.wait_proc(pid) do
      {^pid, status} ->
        {:reply, {:ok, status}, state}

      {0, _} ->
        Process.send_after(self(), {:await_exit, from}, 100)
        {:noreply, state}

      {-1, status} ->
        {:reply, {:error, status}, state}
    end
  end

  # def ps(pid) do
  #   {out, 0} = System.cmd("ps", [to_string(pid)])
  #   out
  # end

  @stdin_close_wait 3000
  @sigterm_wait 1000

  # Try to gracefully terminate external proccess if the genserver associated with the process is killed
  defp start_watcher(pid, stdin) do
    parent = self()

    watcher_pid =
      spawn(fn ->
        ref = Process.monitor(parent)
        send(parent, {self(), :done})

        receive do
          {:DOWN, ^ref, :process, ^parent, _reason} ->
            with {:error, _} <- ProcessHelper.close_pipe(stdin),
                 _ <- :timer.sleep(@stdin_close_wait),
                 {p, _} <- ProcessHelper.wait_proc(pid),
                 false <- p != pid,
                 _ <- ProcessHelper.terminate_proc(pid),
                 _ <- :timer.sleep(@sigterm_wait),
                 {p, _} <- ProcessHelper.wait_proc(pid),
                 false <- p != pid,
                 _ <- ProcessHelper.kill_proc(pid) do
              Logger.debug(fn -> "Killed process: #{pid}" end)
            end
        end
      end)

    receive do
      {^watcher_pid, :done} -> :ok
    end
  end
end
