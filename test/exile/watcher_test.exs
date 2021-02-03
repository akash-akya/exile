defmodule Exile.WatcherTest do
  use ExUnit.Case, async: true
  alias Exile.Process

  test "uds path socket cleanup after successful exit" do
    {:ok, s} = Process.start_link(~w(cat))
    %{socket_path: socket_path} = :sys.get_state(s)

    assert File.exists?(socket_path)

    :ok = Process.close_stdin(s)
    Elixir.Process.sleep(100)

    {:ok, {:exit, 0}} = Process.await_exit(s)
    :ok = Process.stop(s)

    Elixir.Process.sleep(100)

    refute File.exists?(socket_path)
  end

  test "external process and uds path cleanup on error" do
    {:ok, s} = Process.start_link(~w(cat))
    %{socket_path: socket_path} = :sys.get_state(s)
    {:ok, os_pid} = Process.os_pid(s)

    assert File.exists?(socket_path)
    assert os_process_alive?(os_pid)

    Elixir.Process.exit(s, :kill)
    Elixir.Process.sleep(100)

    refute File.exists?(socket_path)
    refute os_process_alive?(os_pid)
  end

  test "if external process is killed with SIGTERM" do
    {:ok, s} = Process.start_link([fixture("ignore_sigterm.sh")])

    {:ok, os_pid} = Process.os_pid(s)
    assert os_process_alive?(os_pid)
    Process.stop(s)

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
