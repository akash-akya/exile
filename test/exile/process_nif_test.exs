defmodule Exile.ProcessNifTest do
  use ExUnit.Case, async: false
  alias Exile.ProcessNif

  test "exit before exec" do
    {:ok, ctx} = ProcessNif.exec_proc(['invalid'], 0)
    :timer.sleep(500)
    assert {:ok, {:exit, 125}} = ProcessNif.wait_proc(ctx)
  end
end
