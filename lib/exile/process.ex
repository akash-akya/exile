defmodule Exile.Process do
  alias Exile.ProcessHelper
  require Logger
  use GenServer

  # delay between retries when io is busy (in milliseconds)
  @default_opts %{io_busy_wait: 1, stderr_to_console: false}

  def start_link(cmd, args, opts \\ %{}) do
    opts = Map.merge(@default_opts, opts)
    GenServer.start(__MODULE__, %{cmd: cmd, args: args, opts: opts})
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

  def await_exit(process, timeout \\ :infinity) do
    GenServer.call(process, :await_exit, timeout)
  end

  def stop(process) do
    GenServer.stop(process, :normal, :infinity)
  end

  ## Server

  def init(%{cmd: cmd, args: args, opts: opts}) do
    path = :os.find_executable(to_charlist(cmd))

    unless path do
      raise "Command not found: #{cmd}"
    end

    {:ok, %{cmd: path, args: args, opts: opts, read_acc: [], errno: nil, status: :init},
     {:continue, nil}}
  end

  def handle_continue(nil, state) do
    exec_args = Enum.map(state.args, &to_charlist/1)
    stderr_to_console = if state.opts.stderr_to_console, do: 1, else: 0

    case ProcessHelper.exec_proc([state.cmd | exec_args], stderr_to_console) do
      {:ok, {pid, stdin, stdout}} ->
        start_watcher(pid, stdin, stdout)
        state = Map.merge(state, %{pid: pid, stdin: stdin, stdout: stdout, status: :start})
        {:noreply, state}

      {:error, errno} ->
        raise "Failed to start command: #{state.cmd}, errno: #{errno}"
    end
  end

  def handle_call(:os_pid, _from, state), do: {:reply, state.pid, state}

  def handle_call(_, _from, %{status: {:exit, status}}), do: {:reply, {:error, {:exit, status}}}

  def handle_call(:await_exit, from, state), do: do_await_exit(state, from)

  def handle_call({:write, _binary}, _from, %{stdin: :closed} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:write, binary}, from, state), do: do_write(state, binary, from)

  def handle_call({:read, bytes}, from, state), do: do_read(state, bytes, from)

  def handle_call(:close_stdin, _from, %{stdin: :closed} = state), do: {:reply, :closed, state}

  def handle_call(:close_stdin, _from, state) do
    case ProcessHelper.close_pipe(state.stdin) do
      :ok -> {:reply, :ok, %{state | stdin: :closed}}
      {:error, errno} -> {:reply, {:error, errno}, %{state | errno: errno}}
    end
  end

  def handle_info({:read, bytes, from}, state), do: do_read(state, bytes, from)

  def handle_info({:write, binary, from}, state), do: do_write(state, binary, from)

  def handle_info({:await_exit, from}, state), do: do_await_exit(state, from)

  defp do_write(state, binary, from) do
    case ProcessHelper.write_proc(state.stdin, binary) do
      {:ok, bytes} ->
        if bytes < IO.iodata_length(binary) do
          binary = IO.iodata_to_binary(binary)
          binary = binary_part(binary, bytes, IO.iodata_length(binary) - bytes)
          Process.send_after(self(), {:write, binary, from}, state.opts.io_busy_wait)
        else
          GenServer.reply(from, :ok)
        end

        {:noreply, state}

      # EAGAIN
      {:error, 35} ->
        Process.send_after(self(), {:write, binary, from}, state.opts.io_busy_wait)
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(from, {:error, errno})
        {:noreply, %{state | errno: errno}}
    end
  end

  defp do_read(state, nil, from) do
    case ProcessHelper.read_proc(state.stdout, 65535) do
      {:ok, <<>>} ->
        GenServer.reply(from, {:eof, []})
        {:noreply, state}

      {:ok, binary} ->
        GenServer.reply(from, {:ok, binary})
        {:noreply, state}

      # EAGAIN
      {:error, 35} ->
        Process.send_after(self(), {:read, nil, from}, state.opts.io_busy_wait)
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(from, {:error, errno})
        {:noreply, %{state | errno: errno}}
    end
  end

  defp do_read(state, bytes, from) do
    case ProcessHelper.read_proc(state.stdout, bytes) do
      {:ok, <<>>} ->
        GenServer.reply(from, {:eof, state.read_acc})
        {:noreply, %{state | read_acc: []}}

      {:ok, binary} ->
        if IO.iodata_length(binary) < bytes do
          Process.send_after(
            self(),
            {:read, bytes - IO.iodata_length(binary), from},
            state.opts.io_busy_wait
          )

          {:noreply, %{state | read_acc: [state.read_acc | binary]}}
        else
          GenServer.reply(from, {:ok, [state.read_acc | binary]})
          {:noreply, %{state | read_acc: []}}
        end

      # EAGAIN
      {:error, 35} ->
        Process.send_after(self(), {:read, bytes, from}, state.opts.io_busy_wait)
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
        Process.send_after(self(), {:await_exit, from}, state.opts.io_busy_wait)
        {:noreply, state}

      {-1, status} ->
        {:reply, {:error, status}, state}
    end
  end

  @stdin_close_wait 3000
  @sigterm_wait 1000

  # Try to gracefully terminate external proccess if the genserver associated with the process is killed
  defp start_watcher(pid, stdin, stdout) do
    parent = self()

    watcher_pid =
      spawn(fn ->
        ref = Process.monitor(parent)
        send(parent, {self(), :done})

        # TODO: should check if process is alreayd exit
        receive do
          {:DOWN, ^ref, :process, ^parent, _reason} ->
            with true <- ProcessHelper.is_alive(pid),
                 _ <- ProcessHelper.close_pipe(stdin),
                 _ <- ProcessHelper.close_pipe(stdout),
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
