defmodule Exile.Watcher do
  use GenServer, restart: :temporary
  require Logger
  alias Exile.ProcessNif

  def start_link(args) do
    {:ok, _pid} = GenServer.start_link(__MODULE__, args)
  end

  def watch(pid, context) do
    spec = {Exile.Watcher, %{pid: pid, context: context}}
    DynamicSupervisor.start_child(Exile.WatcherSupervisor, spec)
  end

  def init(args) do
    %{pid: pid, context: context} = args
    Process.flag(:trap_exit, true)
    ref = Elixir.Process.monitor(pid)
    {:ok, %{pid: pid, context: context, ref: ref}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{pid: pid, context: context, ref: ref}) do
    attempt_graceful_exit(context)
    {:stop, :normal, nil}
  end

  def handle_info({:EXIT, _, reason}, nil), do: {:stop, reason, nil}

  # when watcher is attempted to be killed, we forcefully kill external os process.
  # This can happen when beam receive SIGTERM
  def handle_info({:EXIT, _, reason}, %{pid: pid, context: context}) do
    Logger.debug(fn -> "Watcher exiting. reason: #{inspect(reason)}" end)
    Exile.Process.stop(pid)
    attempt_graceful_exit(context)
    {:stop, reason, nil}
  end

  # for proper process exit parent of the child *must* wait() for
  # child processes termination exit and "pickup" after the exit
  # (receive child exit_status). Resources acquired by child such as
  # file descriptors won't be released even if the child process
  # itself is terminated.
  defp attempt_graceful_exit(context) do
    try do
      Logger.debug(fn -> "Stopping external program" end)

      # sys_close is idempotent, calling it multiple times is okay
      ProcessNif.sys_close(context, ProcessNif.to_process_fd(:stdin))
      ProcessNif.sys_close(context, ProcessNif.to_process_fd(:stdout))

      # at max we wait for 100ms for program to exit
      process_exit?(context, 100) && throw(:done)

      Logger.debug("Failed to stop external program gracefully. attempting SIGTERM")
      ProcessNif.sys_terminate(context)
      process_exit?(context, 100) && throw(:done)

      Logger.debug("Failed to stop external program with SIGTERM. attempting SIGKILL")
      ProcessNif.sys_kill(context)
      process_exit?(context, 1000) && throw(:done)

      Logger.error("[exile] failed to kill external process")
      raise "Failed to kill external process"
    catch
      :done -> Logger.debug(fn -> "External program exited successfully" end)
    end
  end

  defp process_exit?(context) do
    match?({:ok, _}, ProcessNif.sys_wait(context))
  end

  defp process_exit?(context, timeout) do
    if process_exit?(context) do
      true
    else
      :timer.sleep(timeout)
      process_exit?(context)
    end
  end
end
