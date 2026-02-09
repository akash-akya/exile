defmodule ExileTest do
  use ExUnit.Case

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
    proc_stream =
      Exile.stream!(["sh", "-c", "trap '' PIPE; while true; do echo hello || exit 3; done"],
        stderr: :consume
      )

    assert_raise Exile.Stream.AbnormalExit, "program exited with exit status: 3", fn ->
      Enum.take(proc_stream, 1)
    end
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
