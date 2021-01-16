defmodule Exile.ProcessTest do
  use ExUnit.Case, async: true
  alias Exile.Process

  test "read" do
    {:ok, s} = Process.start_link(~w(echo test))
    assert {:eof, iodata} = Process.read(s, 100)
    assert IO.iodata_to_binary(iodata) == "test\n"
    assert :ok == Process.close_stdin(s)
    assert {:ok, {:exit, 0}} == Process.await_exit(s, 500)
    Process.stop(s)
  end

  test "write" do
    {:ok, s} = Process.start_link(~w(cat))
    assert :ok == Process.write(s, "hello")
    assert {:ok, iodata} = Process.read(s, 5)
    assert IO.iodata_to_binary(iodata) == "hello"

    assert :ok == Process.write(s, "world")
    assert {:ok, iodata} = Process.read(s, 5)
    assert IO.iodata_to_binary(iodata) == "world"

    assert :ok == Process.close_stdin(s)
    assert {:eof, []} == Process.read(s)
    assert {:ok, {:exit, 0}} == Process.await_exit(s, 100)
    Process.stop(s)
  end

  test "stdin close" do
    logger = start_events_collector()

    # base64 produces output only after getting EOF from stdin.  we
    # collect events in order and assert that we can still read from
    # stdout even after closing stdin
    {:ok, s} = Process.start_link(~w(base64))

    # parallel reader should be blocked till we close stdin
    start_parallel_reader(s, logger)
    :timer.sleep(100)

    assert :ok == Process.write(s, "hello")
    add_event(logger, {:write, "hello"})
    assert :ok == Process.write(s, "world")
    add_event(logger, {:write, "world"})
    :timer.sleep(100)

    assert :ok == Process.close_stdin(s)
    add_event(logger, :input_close)
    assert {:ok, {:exit, 0}} == Process.await_exit(s, 100)
    Process.stop(s)

    assert [
             {:write, "hello"},
             {:write, "world"},
             :input_close,
             {:read, "aGVsbG93b3JsZA==\n"},
             :eof
           ] == get_events(logger)
  end

  test "external command termination on stop" do
    {:ok, s} = Process.start_link(~w(cat))
    {:ok, os_pid} = Process.os_pid(s)
    assert os_process_alive?(os_pid)

    Process.stop(s)
    :timer.sleep(100)

    refute os_process_alive?(os_pid)
  end

  test "external command kill on stop" do
    # cat command hangs waiting for EOF
    {:ok, s} = Process.start_link([fixture("ignore_sigterm.sh")])

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
    {:ok, s} = Process.start_link(["sh", "-c", "exit 10"])
    assert {:ok, {:exit, 10}} == Process.await_exit(s, 500)
    Process.stop(s)
  end

  test "writing binary larger than pipe buffer size" do
    large_bin = generate_binary(5 * 65535)
    {:ok, s} = Process.start_link(~w(cat))

    writer =
      Task.async(fn ->
        Process.write(s, large_bin)
        Process.close_stdin(s)
      end)

    :timer.sleep(100)

    {_, iodata} = Process.read(s, 5 * 65535)
    Task.await(writer)

    assert IO.iodata_length(iodata) == 5 * 65535
    assert {:ok, {:exit, 0}} == Process.await_exit(s, 500)
    Process.stop(s)
  end

  test "back-pressure" do
    logger = start_events_collector()

    # we test backpressure by testing if `write` is delayed when we delay read
    {:ok, s} = Process.start_link(~w(cat))

    large_bin = generate_binary(65535 * 5)

    writer =
      Task.async(fn ->
        Enum.each(1..10, fn i ->
          Process.write(s, large_bin)
          add_event(logger, {:write, i})
        end)

        Process.close_stdin(s)
      end)

    :timer.sleep(50)

    reader =
      Task.async(fn ->
        Enum.each(1..10, fn i ->
          Process.read(s, 5 * 65535)
          add_event(logger, {:read, i})
          # delay in reading should delay writes
          :timer.sleep(10)
        end)
      end)

    Task.await(writer)
    Task.await(reader)

    assert {:ok, {:exit, 0}} == Process.await_exit(s, 500)
    Process.stop(s)

    assert [
             write: 1,
             read: 1,
             write: 2,
             read: 2,
             write: 3,
             read: 3,
             write: 4,
             read: 4,
             write: 5,
             read: 5,
             write: 6,
             read: 6,
             write: 7,
             read: 7,
             write: 8,
             read: 8,
             write: 9,
             read: 9,
             write: 10,
             read: 10
           ] == get_events(logger)
  end

  # this test does not work properly in linux
  @tag :skip
  test "if we are leaking file descriptor" do
    {:ok, s} = Process.start_link(~w(sleep 60))
    {:ok, os_pid} = Process.os_pid(s)

    # we are only printing FD, TYPE, NAME with respective prefix
    {bin, 0} = System.cmd("lsof", ["-F", "ftn", "-p", to_string(os_pid)])

    Process.stop(s)

    open_files = parse_lsof(bin)
    assert [%{fd: "0", name: _, type: "PIPE"}, %{type: "PIPE", fd: "1", name: _}] = open_files
  end

  test "process kill with pending write" do
    {:ok, s} = Process.start_link(~w(cat))
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

  test "cd" do
    parent = Path.expand("..", File.cwd!())
    {:ok, s} = Process.start_link(~w(sh -c pwd), cd: parent)
    {:ok, dir} = Process.read(s)
    assert String.trim(dir) == parent
    assert {:ok, {:exit, 0}} = Process.await_exit(s)
    Process.stop(s)
  end

  test "invalid path" do
    assert {:error, _} = Process.start_link(~w(sh -c pwd), cd: "invalid")
  end

  test "invalid opt" do
    assert {:error, "invalid opts: [invalid: :test]"} =
             Process.start_link(~w(cat), invalid: :test)
  end

  test "env" do
    assert {:ok, s} = Process.start_link(~w(printenv TEST_ENV), env: %{"TEST_ENV" => "test"})

    assert {:ok, "test\n"} = Process.read(s)
    assert {:ok, {:exit, 0}} = Process.await_exit(s)
    Process.stop(s)
  end

  test "if external process inherits beam env" do
    :ok = System.put_env([{"BEAM_ENV_A", "10"}])
    assert {:ok, s} = Process.start_link(~w(printenv BEAM_ENV_A))

    assert {:ok, "10\n"} = Process.read(s)
    assert {:ok, {:exit, 0}} = Process.await_exit(s)
    Process.stop(s)
  end

  test "if user env overrides beam env" do
    :ok = System.put_env([{"BEAM_ENV", "base"}])

    assert {:ok, s} =
             Process.start_link(~w(printenv BEAM_ENV), env: %{"BEAM_ENV" => "overridden"})

    assert {:ok, "overridden\n"} = Process.read(s)
    assert {:ok, {:exit, 0}} = Process.await_exit(s)
    Process.stop(s)
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

  defp parse_lsof(iodata) do
    String.split(IO.iodata_to_binary(iodata), "\n", trim: true)
    |> Enum.reduce([], fn
      "f" <> fd, acc -> [%{fd: fd} | acc]
      "t" <> type, [h | acc] -> [Map.put(h, :type, type) | acc]
      "n" <> name, [h | acc] -> [Map.put(h, :name, name) | acc]
      _, acc -> acc
    end)
    |> Enum.reverse()
    |> Enum.reject(fn
      %{fd: fd} when fd in ["255", "cwd", "txt"] ->
        true

      %{fd: "rtd", name: "/", type: "DIR"} ->
        true

      # filter libc and friends
      %{fd: "mem", type: "REG", name: "/lib/x86_64-linux-gnu/" <> _} ->
        true

      %{fd: "mem", type: "REG", name: "/usr/lib/locale/C.UTF-8/" <> _} ->
        true

      %{fd: "mem", type: "REG", name: "/usr/lib/locale/locale-archive" <> _} ->
        true

      %{fd: "mem", type: "REG", name: "/usr/lib/x86_64-linux-gnu/gconv" <> _} ->
        true

      _ ->
        false
    end)
  end

  defp generate_binary(size) do
    Stream.repeatedly(fn -> "A" end) |> Enum.take(size) |> IO.iodata_to_binary()
  end
end
