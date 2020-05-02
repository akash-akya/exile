defmodule Exile do
  def stream!(cmd, args \\ []) do
    Exile.Stream.__build__(cmd, args)
  end
end
