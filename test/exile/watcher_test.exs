defmodule Exile.WatcherTest do
  use ExUnit.Case, async: true
  alias Exile.Process

  test "when exile process exit normally" do
    {:ok, s} = Process.start_link(~w(cat))
    {:ok, os_pid} = Process.os_pid(s)

    assert os_process_alive?(os_pid)

    {:ok, 0} = Process.await_exit(s)

    refute os_process_alive?(os_pid)
  end

  test "if external process is cleaned up when Exile Process is killed" do
    parent = self()

    # Exile process is linked to caller so we must run test this in
    # separate process which is not linked
    spawn(fn ->
      {:ok, s} = Process.start_link([fixture("ignore_sigterm.sh")])
      {:ok, os_pid} = Process.os_pid(s)
      assert os_process_alive?(os_pid)
      send(parent, os_pid)

      Elixir.Process.exit(s.pid, :kill)
    end)

    os_pid =
      receive do
        os_pid -> os_pid
      end

    :timer.sleep(1000)

    refute os_process_alive?(os_pid)
  end

  defp os_process_alive?(pid) do
    match?({_, 0}, System.cmd("ps", ["-p", to_string(pid)]))
  end

  defp fixture(script) do
    Path.join([__DIR__, "../scripts", script])
  end
end
