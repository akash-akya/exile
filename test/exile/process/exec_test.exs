defmodule Exile.Process.ExecTest do
  use ExUnit.Case, async: true

  alias Exile.Process.Exec
  alias Exile.Process.Nif

  setup_all do
    directory = Path.join(System.tmp_dir!(), "exile-exec-#{System.pid()}")
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    helper = Path.join(directory, "spawner")
    source = Path.expand("../../scripts/startup_helper.c", __DIR__)
    {output, status} = System.cmd("cc", ["-std=c99", "-Wall", "-Werror", source, "-o", helper])
    assert status == 0, output
    {:ok, helper: helper}
  end

  test "reports a helper exit instead of a socket timeout", %{helper: helper} do
    error = assert_raise Exile.Process.Error, fn -> start_helper(helper, "exit") end
    assert error.reason == :spawner_exit
    assert error.exit_status == 23
    refute error.message =~ "timeout"
  end

  test "times out and closes the port if the helper never connects", %{helper: helper} do
    error = assert_raise Exile.Process.Error, fn -> start_helper(helper, "no_connect") end
    assert error.operation == :accept
    assert error.reason == :timeout

    {:links, links} = Process.info(self(), :links)
    refute Enum.any?(links, &is_port/1)
  end

  test "times out if the helper connects but sends nothing", %{helper: helper} do
    error = assert_raise Exile.Process.Error, fn -> start_helper(helper, "no_message") end
    assert error.operation == :recvmsg
    assert error.reason == :timeout
  end

  test "rejects a handshake without file descriptors", %{helper: helper} do
    error = assert_raise Exile.Process.Error, fn -> start_helper(helper, "no_fds") end
    assert error.reason == :invalid_fd_message
  end

  test "fast commands preserve their handles and exit status" do
    for status <- [0, 7] do
      {:ok, args} = Exec.normalize_exec_args(["sh", "-c", "exit #{status}"], stderr: :consume)
      %{port: port, stdin: stdin, stdout: stdout, stderr: stderr} = Exec.start(args, args.stderr)
      monitor = Port.monitor(port)

      assert_receive {^port, {:exit_status, ^status}}, 1000
      assert_receive {:DOWN, ^monitor, :port, ^port, _reason}
      assert Exec.os_pid(port) == :undefined
      assert :ok = Nif.nif_close(stdin)
      assert :ok = Nif.nif_close(stdout)
      assert :ok = Nif.nif_close(stderr)
    end
  end

  defp start_helper(helper, mode) do
    {:ok, args} = Exec.normalize_exec_args(["true", mode], stderr: :consume)
    Exec.start(args, :consume, helper)
  end
end
