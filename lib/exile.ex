defmodule Exile do
  @moduledoc """
  Exile is an alternative for beam ports with back-pressure and non-blocking IO
  """

  @doc """
  Returns a `Exile.Stream` for the given `cmd` with arguments `args`.

  The stream implements both `Enumerable` and `Collectable` protocols, which means it can be used both for reading from stdout and write to stdin of an OS process simultaneously (see examples).

  `Exile.Stream` works with [iodata](https://hexdocs.pm/elixir/IO.html#module-io-data), chunks emitted by Enumerable is iodata as well. If you want binary please use (`IO.iodata_to_binary/1`)[https://hexdocs.pm/elixir/IO.html#iodata_to_binary/1].

  ### Options
    * `exit_timeout`     - Duration to wait for external program to exit after completion before raising an error. Defaults to `:infinity`
    * `chunk_size`       - Size of each iodata chunk emitted by Enumerable stream
  All other options are passed to `Exile.Process.start_link/3`

  Since execution of external program is independent of beam process, once should prefer feeding input and getting output in separate processes.

  ### Examples

  ``` elixir
  def audio_stream!(stream) do
    # read from stdin and write to stdout
    proc_stream = Exile.stream!("ffmpeg", ~w(-i - -f mp3 -))

    Task.async(fn ->
      Stream.into(stream, proc_stream)
      |> Stream.run()
    end)

    proc_stream
  end

  File.stream!("music_video.mkv", [], 65535)
  |> audio_stream!()
  |> Stream.into(File.stream!("music.mp3"))
  |> Stream.run()
  ```
  """
  def stream!(cmd, args \\ [], opts \\ %{}) do
    Exile.Stream.__build__(cmd, args, opts)
  end
end
