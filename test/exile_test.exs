defmodule ExileTest do
  use ExUnit.Case

  test "stream with enumerable" do
    proc_stream = Exile.stream!(["cat"], input: Stream.map(1..1000, fn _ -> "a" end))
    output = proc_stream |> Enum.to_list()
    assert IO.iodata_length(output) == 1000
  end

  test "stream with collectable" do
    proc_stream =
      Exile.stream!(["cat"], input: fn sink -> Enum.into(1..1000, sink, fn _ -> "a" end) end)

    output = proc_stream |> Enum.to_list()
    assert IO.iodata_length(output) == 1000
  end

  test "stream without stdin" do
    proc_stream = Exile.stream!(~w(echo hello))
    output = proc_stream |> Enum.to_list()
    assert IO.iodata_to_binary(output) == "hello\n"
  end
end
