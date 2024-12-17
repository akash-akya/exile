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
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{pid: pid, ref: ref} = state) do
    %{socket_path: socket_path, os_pid: os_pid} = state
    _ = File.rm(socket_path)

    # Ideally we should skip checking if program is alive if the Exile
    # process is terminated with reason `:normal`. But at the moment
    # when owner process terminates we unconditionally exit
    # potentially with the reason `:normal`, so we can not rely on
    # `:normal` reason

    if !process_dead?(os_pid, 50) do
      attempt_graceful_exit(os_pid)
    end

    {:stop, :normal, nil}
  end

  def handle_info({:EXIT, _, reason}, nil), do: {:stop, reason, nil}

  # when watcher is attempted to be killed, we forcefully kill external os process.
  # This can happen when beam receive SIGTERM
  def handle_info({:EXIT, _, reason}, %{pid: pid, socket_path: socket_path, os_pid: os_pid}) do
    Logger.debug("Watcher exiting. reason: #{inspect(reason)}")
    File.rm!(socket_path)
    Elixir.Process.exit(pid, :watcher_exit)
    attempt_graceful_exit(os_pid)
    {:stop, reason, nil}
  end

  # certain programs such as older version of `parallel` expects
  # multiple `SIGTERM` signals
  @term_seq [sigterm: 150, sigterm: 100, sigkill: 100]

  @spec attempt_graceful_exit(Exile.Process.os_pid()) :: :ok | no_return
  defp attempt_graceful_exit(os_pid) do
    Logger.debug("Starting graceful termination sequence: #{inspect(@term_seq)}")

    dead? =
      Enum.reduce_while(@term_seq, false, fn {signal, wait_time}, _dead? ->
        Nif.nif_kill(os_pid, signal)

        # check process_status first before going to sleep
        if process_dead?(os_pid, wait_time) do
          Logger.debug("External program terminated successfully with signal: #{signal}")
          {:halt, true}
        else
          Logger.debug("Failed to stop with signal: #{signal}, wait_time: #{wait_time}")
          {:cont, false}
        end
      end)

    if dead? do
      :ok
    else
      Logger.error("Failed to kill external process, os_pid #{os_pid}")
      raise "Failed to kill external process"
    end
  end

  @spec process_dead?(Exile.Process.os_pid(), pos_integer) :: boolean
  defp process_dead?(os_pid, wait_time) do
    # check process_status first before going to sleep
    if process_status(os_pid) == :dead do
      true
    else
      Elixir.Process.sleep(wait_time)
      process_status(os_pid) == :dead
    end
  end

  @spec process_status(Exile.Process.os_pid()) :: :alive | :dead
  defp process_status(os_pid) do
    if Nif.nif_is_os_pid_alive(os_pid) do
      :alive
    else
      :dead
    end
  end
end
