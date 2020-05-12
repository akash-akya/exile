defmodule Exile.SyncProcessTest do
  use ExUnit.Case, async: false
  alias Exile.Process

  @bin Stream.repeatedly(fn -> "A" end) |> Enum.take(65535) |> IO.iodata_to_binary()

  test "memory leak" do
    :timer.sleep(1000)
    before_exec = :erlang.memory(:total)

    {:ok, s} = Process.start_link(~w(cat))

    Enum.each(1..500, fn _ ->
      :ok = Process.write(s, @bin)
      {:ok, _} = Process.read(s, 65535)
    end)

    :timer.sleep(1000)
    after_exec = :erlang.memory(:total)

    assert_in_delta before_exec, after_exec, 1024 * 1024

    assert :ok == Process.close_stdin(s)
    assert {:ok, {:exit, 0}} == Process.await_exit(s, 500)
  end
end
