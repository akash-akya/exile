defmodule Exile.SyncProcessTest do
  use ExUnit.Case, async: false
  alias Exile.Process

  @bin Stream.repeatedly(fn -> "A" end) |> Enum.take(65_535) |> IO.iodata_to_binary()

  test "memory leak" do
    :timer.sleep(1000)
    before_exec = :erlang.memory(:total)

    {:ok, s} = Process.start_link(~w(cat))

    Enum.each(1..500, fn _ ->
      :ok = Process.write(s, @bin)
      {:ok, _} = Process.read(s, 65_535)
    end)

    :timer.sleep(1000)
    after_exec = :erlang.memory(:total)

    assert_in_delta before_exec, after_exec, 1024 * 1024

    assert :ok == Process.close_stdin(s)
    assert {:ok, 0} == Process.await_exit(s, 500)
    # Process.stop(s)
  end

  test "if watcher process exits on command exit" do
    stop_all_children(Exile.WatcherSupervisor)

    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(Exile.WatcherSupervisor)
    assert {:ok, s} = Process.start_link(~w(cat))

    # we spawn in background
    :timer.sleep(200)

    assert %{active: 1, workers: 1} = DynamicSupervisor.count_children(Exile.WatcherSupervisor)

    Process.close_stdin(s)
    assert {:ok, 0} = Process.await_exit(s, 500)
    # Process.stop(s)

    # wait for watcher to terminate
    :timer.sleep(200)
    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(Exile.WatcherSupervisor)
  end

  defp stop_all_children(sup) do
    DynamicSupervisor.which_children(sup)
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(sup, pid)
    end)
  end
end
