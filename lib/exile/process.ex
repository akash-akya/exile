defmodule Exile.Process do
  @moduledoc """
  GenServer which wraps spawned external command.

  One should use `ExCmd.stream!` over `Exile.Process`. stream internally manages this server for you. Use this only if you need more control over the  life-cycle OS process.

  ## Overview
  `Exile.Process` is an alternative primitive for Port. It has different interface and approach to running external programs to solve the issues associated with the ports.

  ### When compared to Port
    * it is demand driven. User explicitly has to `read` output of the command and the progress of the external command is controlled using OS pipes. so unlike Port, this never cause memory issues in beam by loading more than we can consume
    * it can close stdin of the program explicitly
    * does not create zombie process. It always tries to cleanup resources

  At high level it makes non-blocking asynchronous system calls to execute and interact with the external program. It completely bypasses beam implementation for the same using NIF. It uses `select()` system call for asynchronous IO. Most of the system calls are non-blocking, so it does not has adverse effect on scheduler. Issues such as "scheduler collapse".

  ### Obligatory NIF warning
  As with any NIF based solution, bugs or issues in Exile implementation can bring down the beam VM. But NIF implementation is comparatively small and mostly uses POSIX system calls, spawned external processes are still completely isolated at OS level and the port issues it tries to solve are critical.
  """

  alias Exile.ProcessNif
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

  def read(process, size) when is_integer(size) do
    GenServer.call(process, {:read, size}, :infinity)
  end

  def read(process) do
    GenServer.call(process, {:read, nil}, :infinity)
  end

  def kill(process, signal) when signal in [:sigkill, :sigterm] do
    GenServer.call(process, {:kill, signal}, :infinity)
  end

  def await_exit(process, timeout \\ :infinity) do
    GenServer.call(process, {:await_exit, timeout}, :infinity)
  end

  def os_pid(process, timeout \\ :infinity) do
    GenServer.call(process, :os_pid, :infinity)
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

    case ProcessNif.exec_proc([state.cmd | exec_args], stderr_to_console) do
      {:ok, context} ->
        start_watcher(context)
        {:noreply, %Process{state | context: context, status: :start}}

      {:error, errno} ->
        raise "Failed to start command: #{state.cmd}, errno: #{errno}"
    end
  end

  def handle_call(:stop, _from, state) do
    # watcher will take care of termination of external process

    # TODO: pending write and read should receive "stopped" return
    # value instead of exit signal
    {:stop, :normal, :ok, state}
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

  def handle_call({:write, binary}, from, state) when is_binary(binary) do
    pending = %Pending{bin: binary, client_pid: from}
    do_write(%Process{state | pending_write: pending})
  end

  def handle_call({:read, bytes}, from, state) do
    pending = %Pending{remaining: bytes, client_pid: from}
    do_read(%Process{state | pending_read: pending})
  end

  def handle_call(:close_stdin, _from, state), do: do_close(state, :stdin)

  def handle_call(:os_pid, _from, state), do: {:reply, ProcessNif.os_pid(state.context), state}

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
    case ProcessNif.write_proc(state.context, pending.bin) do
      {:ok, size} ->
        if size < byte_size(pending.bin) do
          binary = binary_part(pending.bin, size, byte_size(pending.bin) - size)
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
    case ProcessNif.read_proc(state.context, -1) do
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
    case ProcessNif.read_proc(state.context, pending.remaining) do
      {:ok, <<>>} ->
        GenServer.reply(pending.client_pid, {:eof, pending.bin})
        {:noreply, %Process{state | pending_read: %Pending{}}}

      {:ok, binary} ->
        if byte_size(binary) < pending.remaining do
          pending = %Pending{
            pending
            | bin: [pending.bin | binary],
              remaining: pending.remaining - byte_size(binary)
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
    case ProcessNif.wait_proc(state.context) do
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

  defp do_kill(context, :sigkill), do: ProcessNif.kill_proc(context)

  defp do_kill(context, :sigterm), do: ProcessNif.terminate_proc(context)

  defp do_close(state, type) do
    case ProcessNif.close_pipe(state.context, stream_type(type)) do
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

  defp process_exit?(context) do
    match?({:ok, _}, ProcessNif.wait_proc(context))
  end

  defp process_exit?(context, timeout) do
    if process_exit?(context) do
      true
    else
      :timer.sleep(timeout)
      process_exit?(context)
    end
  end

  # for proper process exit parent of the child *must* wait() for
  # child processes termination exit and "pickup" after the exit
  # (receive child exit_status). Resources acquired by child such as
  # file descriptors won't be released even if the child process
  # itself is terminated.
  defp watcher(process_server, context) do
    ref = Elixir.Process.monitor(process_server)
    send(process_server, {self(), :done})

    receive do
      {:DOWN, ^ref, :process, ^process_server, _reason} ->
        try do
          process_exit?(context) && throw(:done)

          Logger.debug(fn -> "Stopping external program" end)
          ProcessNif.close_pipe(context, stream_type(:stdin))
          ProcessNif.close_pipe(context, stream_type(:stdout))

          # at max we wait for 100ms for program to exit
          process_exit?(context, 100) && throw(:done)

          Logger.debug("Failed to stop external program gracefully. attempting SIGTERM")
          ProcessNif.terminate_proc(context)
          process_exit?(context, 100) && throw(:done)

          Logger.debug("Failed to stop external program with SIGTERM. attempting SIGKILL")
          ProcessNif.kill_proc(context)
          process_exit?(context, 1000) && throw(:done)

          Logger.error("[exile] failed to kill external process")
          raise "Failed to kill external process"
        catch
          :done -> Logger.debug(fn -> "Exited external program successfully" end)
        end
    end
  end
end
