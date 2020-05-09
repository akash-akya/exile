defmodule Exile.ProcessTest do
  use ExUnit.Case, async: true
  alias Exile.Process

  test "read" do
    {:ok, s} = Process.start_link("echo", ["test"])
    assert {:ok, "test\n"} == Process.read(s)
    assert {:eof, []} == Process.read(s)
    assert :ok == Process.close_stdin(s)
    assert {:ok, {:exit, 0}} == Process.await_exit(s, 500)
  end

  test "write" do
    {:ok, s} = Process.start_link("cat", [])
    assert :ok == Process.write(s, "hello")
    assert {:ok, "hello"} == Process.read(s)
    assert :ok == Process.write(s, "world")
    assert {:ok, "world"} == Process.read(s)
    assert :ok == Process.close_stdin(s)
    assert {:eof, []} == Process.read(s)
    assert {:ok, {:exit, 0}} == Process.await_exit(s, 100)
  end

  test "stdin close" do
    logger = start_events_collector()

    # base64 produces output only after getting EOF from stdin.  we
    # collect events in order and assert that we can still read from
    # stdout even after closing stdin
    {:ok, s} = Process.start_link("base64", [])

    # parallel reader should be blocked till we close stdin
    start_parallel_reader(s, logger)
    :timer.sleep(50)

    assert :ok == Process.write(s, "hello")
    add_event(logger, {:write, "hello"})
    assert :ok == Process.write(s, "world")
    add_event(logger, {:write, "world"})
    :timer.sleep(50)

    assert :ok == Process.close_stdin(s)
    add_event(logger, :input_close)
    assert {:ok, {:exit, 0}} == Process.await_exit(s, 50)

    assert [
             {:write, "hello"},
             {:write, "world"},
             :input_close,
             {:read, "aGVsbG93b3JsZA==\n"},
             :eof
           ] == get_events(logger)
  end

  test "external command termination on stop" do
    {:ok, s} = Process.start_link("cat", [])
    {:ok, os_pid} = Process.os_pid(s)
    assert os_process_alive?(os_pid)

    Process.stop(s)
    :timer.sleep(100)

    refute os_process_alive?(os_pid)
  end

  test "external command kill on stop" do
    # cat command hangs waiting for EOF
    {:ok, s} = Process.start_link(fixture("ignore_sigterm.sh"), [])

    {:ok, os_pid} = Process.os_pid(s)
    assert os_process_alive?(os_pid)
    Process.stop(s)

    if os_process_alive?(os_pid) do
      :timer.sleep(3000)
      refute os_process_alive?(os_pid)
    else
      :ok
    end
  end

  test "exit status" do
    {:ok, s} = Process.start_link(fixture("exit_with.sh"), ["2"])
    assert {:ok, {:exit, 2}} == Process.await_exit(s, 500)
  end

  test "process kill with pending write" do
    {:ok, s} = Process.start_link("cat", [])
    {:ok, os_pid} = Process.os_pid(s)

    large_data =
      Stream.cycle(["test"]) |> Stream.take(500_000) |> Enum.to_list() |> IO.iodata_to_binary()

    task =
      Task.async(fn ->
        try do
          Process.write(s, large_data)
        catch
          :exit, reason -> reason
        end
      end)

    :timer.sleep(200)
    Process.stop(s)
    :timer.sleep(3000)

    refute os_process_alive?(os_pid)
    assert {:normal, _} = Task.await(task)
  end

  def start_parallel_reader(proc_server, logger) do
    spawn_link(fn -> reader_loop(proc_server, logger) end)
  end

  def reader_loop(proc_server, logger) do
    case Process.read(proc_server) do
      {:ok, data} ->
        add_event(logger, {:read, data})
        reader_loop(proc_server, logger)

      {:eof, []} ->
        add_event(logger, :eof)
    end
  end

  def start_events_collector do
    {:ok, ordered_events} = Agent.start(fn -> [] end)
    ordered_events
  end

  def add_event(agent, event) do
    :ok = Agent.update(agent, fn events -> events ++ [event] end)
  end

  def get_events(agent) do
    Agent.get(agent, & &1)
  end

  defp os_process_alive?(pid) do
    match?({_, 0}, System.cmd("ps", ["-p", to_string(pid)]))
  end

  defp fixture(script) do
    Path.join([__DIR__, "../scripts", script])
  end
end
