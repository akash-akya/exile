defmodule Exile.Process.ExecTest do
  use ExUnit.Case, async: true

  alias Exile.Process.Exec
  alias Exile.Process.Nif

  test "start/2 returns process handles for a fast-exiting command" do
    {:ok, args} = Exec.normalize_exec_args(["sh", "-c", "exit 0"], stderr: :consume)

    %{port: port, stdin: stdin, stdout: stdout, stderr: stderr} = Exec.start(args, args.stderr)

    assert is_port(port)
    assert not is_nil(stdin)
    assert not is_nil(stdout)
    assert not is_nil(stderr)

    assert :ok = Nif.nif_close(stdin)
    assert :ok = Nif.nif_close(stdout)
    assert :ok = Nif.nif_close(stderr)
  end

  test "os_pid/1 can be unavailable shortly after start when command exits quickly" do
    {:ok, args} = Exec.normalize_exec_args(["sh", "-c", "exit 0"], stderr: :consume)

    %{port: port, stdin: stdin, stdout: stdout, stderr: stderr} = Exec.start(args, args.stderr)

    assert :ok = Nif.nif_close(stdin)
    assert :ok = Nif.nif_close(stdout)
    assert :ok = Nif.nif_close(stderr)

    Process.sleep(5)
    assert :undefined == Exec.os_pid(port)
  end
end
