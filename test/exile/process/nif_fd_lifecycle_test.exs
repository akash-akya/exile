defmodule Exile.Process.NifFdLifecycleTest do
  use ExUnit.Case, async: false

  alias Exile.Process.Exec
  alias Exile.Process.Nif
  alias Exile.Process.Pipe

  defp start_cat! do
    {:ok, args} = Exec.normalize_exec_args(~w(cat), stderr: :consume)
    Exec.start(args, args.stderr)
  end

  defp cleanup_handles(%{port: port, stdin: stdin, stdout: stdout, stderr: stderr}) do
    _ = Nif.nif_close(stdin)
    _ = Nif.nif_close(stdout)
    _ = Nif.nif_close(stderr)

    if is_port(port) and Port.info(port) != nil do
      _ = Port.close(port)
    end
  end

  test "write after close returns invalid_fd_resource instead of raw errno" do
    handles = start_cat!()
    on_exit(fn -> cleanup_handles(handles) end)

    assert :ok = Nif.nif_close(handles.stdin)
    assert {:error, :invalid_fd_resource} = Nif.nif_write(handles.stdin, "x")
  end

  test "read after close returns invalid_fd_resource instead of raw errno" do
    handles = start_cat!()
    on_exit(fn -> cleanup_handles(handles) end)

    assert :ok = Nif.nif_close(handles.stdout)
    assert {:error, :invalid_fd_resource} = Nif.nif_read(handles.stdout, 64)
  end

  test "only resource owner can close fd resource" do
    handles = start_cat!()
    on_exit(fn -> cleanup_handles(handles) end)

    non_owner_result =
      Task.async(fn ->
        Nif.nif_close(handles.stdin)
      end)
      |> Task.await()

    assert {:error, :invalid_fd_resource} = non_owner_result
    assert :ok = Nif.nif_close(handles.stdin)
  end

  test "pipe read/write map invalid fd resource to pipe_closed_or_invalid_caller" do
    handles = start_cat!()
    on_exit(fn -> cleanup_handles(handles) end)

    stdin_pipe = %Pipe{name: :stdin, fd: handles.stdin, owner: self(), status: :open}
    stdout_pipe = %Pipe{name: :stdout, fd: handles.stdout, owner: self(), status: :open}

    assert :ok = Nif.nif_close(handles.stdin)
    assert :ok = Nif.nif_close(handles.stdout)

    assert {:error, :pipe_closed_or_invalid_caller} = Pipe.write(stdin_pipe, "x", self())
    assert {:error, :pipe_closed_or_invalid_caller} = Pipe.read(stdout_pipe, 64, self())
  end
end
