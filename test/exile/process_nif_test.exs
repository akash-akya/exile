defmodule Exile.ProcessNifTest do
  use ExUnit.Case, async: false
  alias Exile.ProcessNif

  test "exit before exec" do
    {:ok, ctx} = ProcessNif.execute(['invalid'], 0)
    :timer.sleep(500)
    assert {:ok, {:exit, 125}} = ProcessNif.sys_wait(ctx)
  end
end
