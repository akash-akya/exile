defmodule Exile.Watcher do
  @moduledoc false

  use GenServer, restart: :temporary

  require Logger
  alias Exile.Process.Nif, as: Nif

  def start_link(args) do
    {:ok, _pid} = GenServer.start_link(__MODULE__, args)
  end

  def watch(pid, os_pid, socket_path) do
    spec = {Exile.Watcher, %{pid: pid, os_pid: os_pid, socket_path: socket_path}}
    DynamicSupervisor.start_child(Exile.WatcherSupervisor, spec)
  end

  @impl true
  def init(args) do
    %{pid: pid, os_pid: os_pid, socket_path: socket_path} = args
    Process.flag(:trap_exit, true)
    ref = Elixir.Process.monitor(pid)
    {:ok, %{pid: pid, os_pid: os_pid, socket_path: socket_path, ref: ref}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{
        pid: pid,
        socket_path: socket_path,
        os_pid: os_pid,
        ref: ref
      }) do
    _ = File.rm(socket_path)
    # at max we wait for 50ms for program to exit
    if process_exit?(os_pid, 50) do
      :ok
    else
      attempt_graceful_exit(os_pid)
    end

    {:stop, :normal, nil}
  end

  def handle_info({:EXIT, _, reason}, nil), do: {:stop, reason, nil}

  # when watcher is attempted to be killed, we forcefully kill external os process.
  # This can happen when beam receive SIGTERM
  def handle_info({:EXIT, _, reason}, %{pid: pid, socket_path: socket_path, os_pid: os_pid}) do
    Logger.debug(fn -> "Watcher exiting. reason: #{inspect(reason)}" end)
    File.rm!(socket_path)
    Elixir.Process.exit(pid, :watcher_exit)
    attempt_graceful_exit(os_pid)
    {:stop, reason, nil}
  end

  defp attempt_graceful_exit(os_pid) do
    Logger.debug("Failed to stop external program gracefully. attempting SIGTERM")
    Nif.nif_kill(os_pid, :sigterm)
    process_exit?(os_pid, 100) && throw(:done)

    Logger.debug("Failed to stop external program with SIGTERM. attempting SIGKILL")
    Nif.nif_kill(os_pid, :sigkill)
    process_exit?(os_pid, 200) && throw(:done)

    Logger.error("failed to kill external process")
    raise "Failed to kill external process"
  catch
    :done ->
      Logger.debug(fn -> "External program exited successfully" end)
  end

  defp process_exit?(os_pid), do: !Nif.nif_is_os_pid_alive(os_pid)

  defp process_exit?(os_pid, timeout) do
    if process_exit?(os_pid) do
      true
    else
      :timer.sleep(timeout)
      process_exit?(os_pid)
    end
  end
end
