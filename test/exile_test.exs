defmodule ExileTest do
  use ExUnit.Case

  alias Exile.Process.Nif

  @write_stderr Path.join(__DIR__, "scripts/write_stderr.sh")

  doctest Exile

  test "stream with enumerable" do
    proc_stream =
      Exile.stream!(["cat"], input: Stream.map(1..1000, fn _ -> "a" end), stderr: :console)

    stdout = proc_stream |> Enum.to_list()
    assert IO.iodata_length(stdout) == 1000
  end

  test "stream with collectable" do
    proc_stream =
      Exile.stream!(["cat"], input: fn sink -> Enum.into(1..1000, sink, fn _ -> "a" end) end)

    stdout = Enum.to_list(proc_stream)
    assert IO.iodata_length(stdout) == 1000
  end

  test "stream without stdin" do
    proc_stream = Exile.stream!(~w(echo hello))
    stdout = Enum.to_list(proc_stream)
    assert IO.iodata_to_binary(stdout) == "hello\n"
  end

  test "stderr to console" do
    {output, exit_status} = run_in_shell([@write_stderr, "Hello World"], stderr: :console)
    assert output == "Hello World\n"
    assert exit_status == 0
  end

  test "stderr disabled" do
    {output, exit_status} = run_in_shell([@write_stderr, "Hello World"], stderr: :disable)
    assert output == ""
    assert exit_status == 0
  end

  test "stderr consume" do
    proc_stream = Exile.stream!([fixture("write_stderr.sh"), "Hello World"], stderr: :consume)

    assert {[], stderr} = split_stream(proc_stream)
    assert IO.iodata_to_binary(stderr) == "Hello World\n"
  end

  test "stderr redirect_to_stdout" do
    merged_output =
      Exile.stream!(
        [fixture("write_stderr.sh"), "Hello World"],
        stderr: :redirect_to_stdout
      )
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert merged_output == "Hello World\n"
  end

  test "order must be preserved when stderr is redirect to stdout" do
    merged_output =
      Exile.stream!(
        ["sh", "-c", "for s in $(seq 1 10); do echo stdout $s; echo stderr $s >&2; done"],
        stderr: :redirect_to_stdout,
        ignore_epipe: true
      )
      |> Enum.to_list()
      |> IO.iodata_to_binary()
      |> String.trim()

    assert [
             "stdout 1",
             "stderr 1",
             "stdout 2",
             "stderr 2",
             "stdout 3",
             "stderr 3",
             "stdout 4",
             "stderr 4",
             "stdout 5",
             "stderr 5",
             "stdout 6",
             "stderr 6",
             "stdout 7",
             "stderr 7",
             "stdout 8",
             "stderr 8",
             "stdout 9",
             "stderr 9",
             "stdout 10",
             "stderr 10"
           ] == String.split(merged_output, "\n")
  end

  test "multiple streams" do
    script = """
    for i in {1..1000}; do
      echo "foo ${i}"
      echo "bar ${i}" >&2
    done
    """

    proc_stream = Exile.stream!(["sh", "-c", script], stderr: :consume)

    {stdout, stderr} = split_stream(proc_stream)

    stdout_lines = String.split(Enum.join(stdout), "\n", trim: true)
    stderr_lines = String.split(Enum.join(stderr), "\n", trim: true)

    assert length(stdout_lines) == length(stderr_lines)
    assert Enum.all?(stdout_lines, &String.starts_with?(&1, "foo "))
    assert Enum.all?(stderr_lines, &String.starts_with?(&1, "bar "))
  end

  # Stress coverage for intermittent FD lifecycle regressions under high parallel load.
  # Excluded from default CI via `test_helper.exs` to avoid flaky PR runs.
  @tag :stress
  test "many concurrent streams do not fail with fd errors" do
    total_streams = 160
    max_concurrency = 40

    failures =
      1..total_streams
      |> Task.async_stream(
        fn _ ->
          try do
            stream_output =
              Exile.stream!(["sh", "-c", "head -c 4096 /dev/zero"],
                stderr: :consume,
                max_chunk_size: 512
              )
              |> Enum.to_list()

            {stdout_size, stderr_size} =
              Enum.reduce(stream_output, {0, 0}, fn
                {:stdout, chunk}, {stdout, stderr} ->
                  {stdout + IO.iodata_length(chunk), stderr}

                {:stderr, chunk}, {stdout, stderr} ->
                  {stdout, stderr + IO.iodata_length(chunk)}
              end)

            if stdout_size == 4096 and stderr_size == 0 do
              :ok
            else
              {:error, {:unexpected_stream_sizes, stdout_size, stderr_size}}
            end
          rescue
            e in Exile.Stream.AbnormalExit ->
              {:error, {:abnormal_exit, e.exit_status, e.message}}

            e ->
              {:error, {:exception, Exception.message(e)}}
          catch
            kind, reason ->
              {:error, {:caught, kind, reason}}
          end
        end,
        max_concurrency: max_concurrency,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.reduce([], fn
        {:ok, :ok}, acc -> acc
        {:ok, {:error, reason}}, acc -> [reason | acc]
        {:exit, reason}, acc -> [{:task_exit, reason} | acc]
      end)
      |> Enum.reverse()

    assert failures == []
  end

  test "environment variable" do
    output =
      Exile.stream!(~w(printenv FOO), env: %{"FOO" => "bar"})
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert output == "bar\n"
  end

  test "premature stream termination" do
    input_stream = Stream.map(1..100_000, fn _ -> "hello" end)

    assert_raise Exile.Stream.AbnormalExit,
                 "program exited due to :epipe error",
                 fn ->
                   Exile.stream!(~w(cat), input: input_stream)
                   |> Enum.take(1)
                 end
  end

  test "premature stream termination when ignore_epipe is true" do
    input_stream = Stream.map(1..100_000, fn _ -> "hello" end)

    assert ["hello"] ==
             Exile.stream!(~w(cat), input: input_stream, ignore_epipe: true, max_chunk_size: 5)
             |> Enum.take(1)
  end

  test "premature stream termination surfaces program exit status when no writer epipe is present" do
    for stream_fun <- [&Exile.stream/2, &Exile.stream!/2] do
      proc_stream =
        stream_fun.(["sh", "-c", "trap '' PIPE; while true; do echo hello || exit 3; done"],
          stderr: :consume
        )

      assert_raise Exile.Stream.AbnormalExit, "program exited with exit status: 3", fn ->
        Enum.take(proc_stream, 1)
      end
    end
  end

  test "normal EOF ignores the cancellation timeout" do
    stream =
      Exile.stream!(["sh", "-c", "exec 1>&- 2>&-; exec sleep 0.2"],
        stderr: :consume,
        exit_timeout: :infinity,
        cancel_timeout: 100
      )

    assert Enum.to_list(stream) == []
  end

  @tag timeout: 1000
  test "normal EOF respects the exit timeout" do
    stream =
      Exile.stream(["sh", "-c", "exec 1>&- 2>&-; exec sleep 10"],
        stderr: :consume,
        exit_timeout: 200,
        cancel_timeout: :infinity
      )

    assert Enum.to_list(stream) == [{:exit, {:status, 143}}]
  end

  @tag timeout: 2000
  test "early halt has a finite default timeout even when exit_timeout is infinite" do
    stream =
      Exile.stream(["sh", "-c", "read ready; printf ready; exec sleep 10"],
        input: stalled_input(self()),
        exit_timeout: :infinity,
        ignore_epipe: true
      )

    assert Enum.take(stream, 1) == ["ready"]
    assert_stream_cleaned_up()
  end

  @tag timeout: 1000
  test "cancellation gives the command and input task separate timeouts" do
    stream =
      Exile.stream(["sh", "-c", "trap '' TERM; read ready; printf ready; exec sleep 10"],
        input: stalled_input(self()),
        exit_timeout: :infinity,
        cancel_timeout: 300,
        ignore_epipe: true
      )

    {elapsed_us, output} = :timer.tc(fn -> Enum.take(stream, 1) end)

    assert output == ["ready"]
    # A shared 300 ms budget would finish before this.
    assert elapsed_us > 400_000
    assert_stream_cleaned_up()
  end

  @tag timeout: 1000
  test "consumer exceptions and their stack traces survive cancellation" do
    stream =
      Exile.stream!(["sh", "-c", "read ready; printf ready; exec sleep 10"],
        input: stalled_input(self()),
        exit_timeout: :infinity,
        cancel_timeout: 200
      )

    try do
      Enum.each(stream, &fail_consumer/1)
      flunk("expected the consumer exception")
    rescue
      error in RuntimeError ->
        assert error.message == "invalid output format"
        assert [{__MODULE__, :fail_consumer, 1, _location} | _] = __STACKTRACE__
    end

    assert_stream_cleaned_up()
  end

  @tag timeout: 1000
  test "input callback exceptions interrupt a blocked reader and preserve the stack trace" do
    parent = self()

    stream =
      Exile.stream!(["sleep", "10"],
        input: fn sink ->
          process = sink.process
          {:ok, os_pid} = Exile.Process.os_pid(process)
          send(parent, {:input_resources, self(), process.pid, os_pid})
          Process.sleep(50)
          fail_input()
        end,
        cancel_timeout: 200
      )

    try do
      Enum.to_list(stream)
      flunk("expected the input exception")
    rescue
      error in RuntimeError ->
        assert error.message == "input producer failed"
        assert [{__MODULE__, :fail_input, 0, _location} | _] = __STACKTRACE__
    end

    assert_stream_cleaned_up()
  end

  @tag timeout: 1000
  test "input enumerable failure cancels the completion wait after EOF" do
    failing_input =
      Stream.repeatedly(fn ->
        Process.sleep(50)
        fail_input()
      end)

    for exit_timeout <- [:infinity, 5000] do
      stream =
        Exile.stream!(["sh", "-c", "read ready; exec 1>&- 2>&-; exec sleep 10"],
          input: Stream.concat(["ready\n"], failing_input),
          stderr: :consume,
          exit_timeout: exit_timeout,
          cancel_timeout: 200
        )

      assert_raise RuntimeError, "input producer failed", fn -> Enum.to_list(stream) end
    end
  end

  test "successful command exit does not hide an input failure" do
    stream =
      Exile.stream(["sh", "-c", "read ready; exit 0"],
        input: fn sink ->
          :ok = Enum.into(["ready\n"], sink)
          Process.sleep(50)
          fail_input()
        end,
        ignore_epipe: true
      )

    assert_raise RuntimeError, "input producer failed", fn -> Enum.to_list(stream) end
  end

  test "input throws propagate to the caller" do
    stream =
      Exile.stream(["cat"],
        input: fn _sink -> throw(:producer_failed) end,
        cancel_timeout: 200
      )

    assert catch_throw(Enum.to_list(stream)) == :producer_failed
  end

  test "input exits propagate to the caller" do
    stream =
      Exile.stream(["cat"],
        input: fn _sink -> exit(:producer_failed) end,
        cancel_timeout: 200
      )

    assert catch_exit(Enum.to_list(stream)) == :producer_failed
  end

  test "suspended enumeration resumes through the final exit status" do
    stream = Exile.stream(["sh", "-c", "printf ready; exit 7"])

    assert {:suspended, ["ready"], continuation} =
             Enumerable.reduce(stream, {:cont, []}, fn element, acc ->
               {:suspend, [element | acc]}
             end)

    assert {:suspended, output, continuation} = continuation.({:cont, ["ready"]})
    assert output == [{:exit, {:status, 7}}, "ready"]
    assert {:halted, ^output} = continuation.({:cont, output})
  end

  test "reduce_while can consume stream/2 and return exit payload" do
    proc_stream = Exile.stream(["sh", "-c", "echo out; echo err >&2; exit 3"], stderr: :consume)

    result =
      Enum.reduce_while(proc_stream, {[], []}, fn
        {:stdout, chunk}, {stdout_acc, stderr_acc} ->
          {:cont, {[stdout_acc | chunk], stderr_acc}}

        {:stderr, chunk}, {stdout_acc, stderr_acc} ->
          {:cont, {stdout_acc, [stderr_acc | chunk]}}

        {:exit, {:status, exit_status}}, {stdout_acc, stderr_acc} ->
          {:halt,
           %{
             exit_status: exit_status,
             stdout: String.trim(IO.iodata_to_binary(stdout_acc)),
             stderr: String.trim(IO.iodata_to_binary(stderr_acc))
           }}
      end)

    assert %{exit_status: 3, stdout: "out", stderr: "err"} = result
  end

  test "stream!/2 with exit status" do
    proc_stream = Exile.stream!(["sh", "-c", "exit 10"])

    assert_raise Exile.Stream.AbnormalExit, "program exited with exit status: 10", fn ->
      Enum.to_list(proc_stream)
    end
  end

  test "stream/2 with exit status" do
    proc_stream = Exile.stream(["sh", "-c", "exit 10"])
    stdout = Enum.to_list(proc_stream)
    assert stdout == [{:exit, {:status, 10}}]
  end

  test "stream!/2 abnormal exit status" do
    proc_stream = Exile.stream!(["sh", "-c", "exit 5"])

    exit_status =
      try do
        proc_stream
        |> Enum.to_list()

        nil
      rescue
        e in Exile.Stream.AbnormalExit ->
          e.exit_status
      end

    assert exit_status == 5
  end

  defp stalled_input(parent) do
    fn sink ->
      process = sink.process
      {:ok, os_pid} = Exile.Process.os_pid(process)
      send(parent, {:input_resources, self(), process.pid, os_pid})
      :ok = Enum.into(["ready\n"], sink)

      Process.sleep(:infinity)
    end
  end

  defp assert_stream_cleaned_up do
    assert_receive {:input_resources, writer_pid, process_pid, os_pid}
    refute Process.alive?(writer_pid)
    refute Nif.nif_is_os_pid_alive(os_pid)
    monitor = Process.monitor(process_pid)
    assert_receive {:DOWN, ^monitor, :process, ^process_pid, _reason}, 1000
  end

  defp fail_consumer(_chunk), do: raise("invalid output format")

  defp fail_input do
    raise "input producer failed"
  end

  defp split_stream(stream) do
    {stdout, stderr} =
      Enum.reduce(stream, {[], []}, fn
        {:stdout, data}, {stdout, stderr} -> {[data | stdout], stderr}
        {:stderr, data}, {stdout, stderr} -> {stdout, [data | stderr]}
      end)

    {Enum.reverse(stdout), Enum.reverse(stderr)}
  end

  defp fixture(script) do
    Path.join([__DIR__, "scripts", script])
  end

  # runs the given code in a separate mix shell and captures all the
  # output written to the shell during the execution the output can be
  # from the elixir or from the spawned command
  defp run_in_shell(args, opts) do
    expr = ~s{Exile.stream!(#{inspect(args)}, #{inspect(opts)}) |> Enum.to_list()}

    {_output, _exit_status} =
      System.cmd("sh", ["-c", "mix run -e '#{expr}'"],
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )
  end
end
