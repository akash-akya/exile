defmodule Exile.Process do
  alias Exile.ProcessHelper
  require Logger
  use GenServer

  defmacro eagain(), do: 35

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

  def kill(process, signal) when signal in [:sigkill, :sigterm] do
    GenServer.call(process, {:kill, signal}, :infinity)
  end

  def await_exit(process, timeout \\ :infinity) do
    GenServer.call(process, {:await_exit, timeout}, :infinity)
  end

  def stop(process), do: GenServer.call(process, :stop, :infinity)

  ## Server

  defmodule Pending do
    defstruct bin: [], remaining: 0, client_pid: nil
  end

  defstruct [
    :cmd,
    :cmd_args,
    :opts,
    :errno,
    :context,
    :status,
    await: %{},
    pending_read: nil,
    pending_write: nil
  ]

  alias __MODULE__

  def init(%{cmd: cmd, args: args, opts: opts}) do
    path = :os.find_executable(to_charlist(cmd))

    unless path do
      raise "Command not found: #{cmd}"
    end

    state = %__MODULE__{
      cmd: path,
      cmd_args: args,
      opts: opts,
      errno: nil,
      status: :init,
      await: %{},
      pending_read: %Pending{},
      pending_write: %Pending{}
    }

    {:ok, state, {:continue, nil}}
  end

  def handle_continue(nil, state) do
    exec_args = Enum.map(state.cmd_args, &to_charlist/1)
    stderr_to_console = if state.opts.stderr_to_console, do: 1, else: 0

    case ProcessHelper.exec_proc([state.cmd | exec_args], stderr_to_console) do
      {:ok, context} ->
        start_watcher(context)
        {:noreply, %Process{state | context: context, status: :start}}

      {:error, errno} ->
        raise "Failed to start command: #{state.cmd}, errno: #{errno}"
    end
  end

  def handle_call(:stop, _from, state) do
    if ProcessHelper.is_alive(state.context) do
      do_close(state, :stdin)
      do_close(state, :stdout)
      do_kill(state.context, :sigkill)
      {:stop, :process_killed, :ok, %{state | status: {:exit, :killed}}}
    else
      {:stop, :normal, :ok, state}
    end
  end

  def handle_call(_, _from, %{status: {:exit, status}}), do: {:reply, {:error, {:exit, status}}}

  def handle_call({:await_exit, timeout}, from, state) do
    tref =
      if timeout != :infinity do
        Elixir.Process.send_after(self(), {:await_exit_timeout, from}, timeout)
      else
        nil
      end

    state = put_timer(state, from, :timeout, tref)
    check_exit(state, from)
  end

  def handle_call({:write, binary}, from, state) do
    pending = %Pending{bin: binary, client_pid: from}
    do_write(%Process{state | pending_write: pending})
  end

  def handle_call({:read, bytes}, from, state) do
    pending = %Pending{remaining: bytes, client_pid: from}
    do_read(%Process{state | pending_read: pending})
  end

  def handle_call(:close_stdin, _from, state), do: do_close(state, :stdin)

  def handle_call({:kill, signal}, _from, state) do
    do_kill(state.context, signal)
    {:reply, :ok, %{state | status: {:exit, :killed}}}
  end

  def handle_info({:check_exit, from}, state), do: check_exit(state, from)

  def handle_info({:await_exit_timeout, from}, state) do
    cancel_timer(state, from, :check)

    receive do
      {:check_exit, ^from} -> :ok
    after
      0 -> :ok
    end

    GenServer.reply(from, :timeout)
    {:noreply, clear_await(state, from)}
  end

  def handle_info({:select, context, _ref, :ready_output}, state) do
    do_write(%Process{state | context: context})
  end

  def handle_info({:select, context, _ref, :ready_input}, state) do
    do_read(%Process{state | context: context})
  end

  def handle_info(msg, _state), do: raise(msg)

  defp do_write(%Process{pending_write: pending} = state) do
    case ProcessHelper.write_proc(state.context, pending.bin) do
      {:ok, size} ->
        if size < IO.iodata_length(pending.bin) do
          binary = IO.iodata_to_binary(pending.bin)
          binary = binary_part(binary, size, IO.iodata_length(pending.bin) - size)
          {:noreply, %{state | pending_write: %Pending{bin: binary}}}
        else
          GenServer.reply(pending.client_pid, :ok)
          {:noreply, %{state | pending_write: %Pending{}}}
        end

      {:error, eagain()} ->
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(pending.client_pid, {:error, errno})
        {:noreply, %{state | errno: errno}}
    end
  end

  defp do_read(%Process{pending_read: %Pending{remaining: nil} = pending} = state) do
    case ProcessHelper.read_proc(state.context, -1) do
      {:ok, <<>>} ->
        GenServer.reply(pending.client_pid, {:eof, []})
        {:noreply, state}

      {:ok, binary} ->
        GenServer.reply(pending.client_pid, {:ok, binary})
        {:noreply, state}

      {:error, eagain()} ->
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(pending.client_pid, {:error, errno})
        {:noreply, %{state | errno: errno}}
    end
  end

  defp do_read(%Process{pending_read: pending} = state) do
    case ProcessHelper.read_proc(state.context, pending.remaining) do
      {:ok, <<>>} ->
        GenServer.reply(pending.client_pid, {:eof, pending.bin})
        {:noreply, %Process{state | pending_read: %Pending{}}}

      {:ok, binary} ->
        if IO.iodata_length(binary) < pending.remaining do
          pending = %Pending{
            pending
            | bin: [pending.bin | binary],
              remaining: pending.remaining - IO.iodata_length(binary)
          }

          {:noreply, %Process{state | pending_read: pending}}
        else
          GenServer.reply(pending.client_pid, {:ok, [state.pending_read.bin | binary]})
          {:noreply, %Process{state | pending_read: %Pending{}}}
        end

      {:error, eagain()} ->
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(pending.client_pid, {:error, errno})
        {:noreply, %{state | pending_read: %Pending{}, errno: errno}}
    end
  end

  defp check_exit(state, from) do
    case ProcessHelper.wait_proc(state.context) do
      {:ok, status} ->
        GenServer.reply(from, {:ok, status})
        cancel_timer(state, from, :timeout)
        {:noreply, clear_await(state, from)}

      {:error, {0, _}} ->
        # Ideally we should not poll and we should handle this with SIGCHLD signal
        tref = Elixir.Process.send_after(self(), {:check_exit, from}, state.opts.io_busy_wait)
        {:noreply, put_timer(state, from, :check, tref)}

      {:error, {-1, status}} ->
        GenServer.reply(from, {:error, status})
        cancel_timer(state, from, :timeout)
        {:noreply, clear_await(state, from)}
    end
  end

  defp do_kill(context, :sigkill), do: ProcessHelper.kill_proc(context)

  defp do_kill(context, :sigterm), do: ProcessHelper.terminate_proc(context)

  defp do_close(state, type) do
    case ProcessHelper.close_pipe(state.context, stream_type(type)) do
      :ok ->
        {:reply, :ok, state}

      {:error, errno} ->
        raise errno
        {:reply, {:error, errno}, %Process{state | errno: errno}}
    end
  end

  defp clear_await(state, from) do
    %Process{state | await: Map.delete(state.await, from)}
  end

  defp cancel_timer(state, from, key) do
    case get_timer(state, from, key) do
      nil -> :ok
      tref -> Elixir.Process.cancel_timer(tref)
    end
  end

  defp put_timer(state, from, key, timer) do
    if Map.has_key?(state.await, from) do
      await = put_in(state.await, [from, key], timer)
      %Process{state | await: await}
    else
      %Process{state | await: %{from => %{key => timer}}}
    end
  end

  defp get_timer(state, from, key), do: get_in(state.await, [from, key])

  @stdin_close_wait 3000
  @sigterm_wait 1000

  # Try to gracefully terminate external proccess if the genserver associated with the process is killed
  defp start_watcher(context) do
    process_server = self()
    watcher_pid = spawn(fn -> watcher(process_server, context) end)

    receive do
      {^watcher_pid, :done} -> :ok
    end
  end

  defp stream_type(:stdin), do: 0
  defp stream_type(:stdout), do: 1

  defp watcher(process_server, context) do
    ref = Elixir.Process.monitor(process_server)
    send(process_server, {self(), :done})

    receive do
      {:DOWN, ^ref, :process, ^process_server, :normal} ->
        :ok

      {:DOWN, ^ref, :process, ^process_server, _reason} ->
        case ProcessHelper.wait_proc(context) do
          {:ok, _status} ->
            # TODO: check stauts
            nil

          {:error, {_, _}} ->
            Logger.debug(fn -> "Killing" end)

            with _ <- ProcessHelper.close_pipe(context, stream_type(:stdin)),
                 _ <- ProcessHelper.close_pipe(context, stream_type(:stdout)),
                 _ <- :timer.sleep(@stdin_close_wait),
                 {:error, _} <- ProcessHelper.wait_proc(context),
                 _ <- ProcessHelper.terminate_proc(context),
                 _ <- :timer.sleep(@sigterm_wait),
                 {:error, _} <- ProcessHelper.wait_proc(context),
                 _ <- ProcessHelper.kill_proc(context) do
              Logger.debug(fn -> "Killed process" end)
            end
        end
    end
  end
end
