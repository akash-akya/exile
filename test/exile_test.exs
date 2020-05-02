defmodule ExileTest do
  use ExUnit.Case

  test "stream" do
    str = "hello"

    proc_stream = Exile.stream!("cat")

    Task.async(fn ->
      Stream.map(1..1000, fn _ -> str end)
      |> Enum.into(proc_stream)
    end)

    output =
      proc_stream
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert IO.iodata_length(output) == 1000 * String.length(str)
  end

  test "stream without stdin" do
    proc_stream = Exile.stream!("echo", ["hello"])
    output = proc_stream |> Enum.to_list()
    assert IO.iodata_to_binary(output) == "hello\n"
  end
end
