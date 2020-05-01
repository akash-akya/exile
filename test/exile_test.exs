defmodule ExileTest do
  use ExUnit.Case
  doctest Exile

  test "greets the world" do
    assert Exile.hello() == :world
  end
end
