defmodule Exile do
  @moduledoc """
  Exile is an alternative for beam ports with back-pressure and non-blocking IO
  """

  use Application

  @doc false
  def start(_type, _args) do
    opts = [
      name: Exile.WatcherSupervisor,
      strategy: :one_for_one
    ]

    # we use DynamicSupervisor for cleaning up external processes on
    # :init.stop or SIGTERM
    DynamicSupervisor.start_link(opts)
  end

  @doc """
  Runs the given command with arguments and return an Enumerable to read command output.

  First parameter must be a list containing command with arguments. example: `["cat", "file.txt"]`.

  ### Options
    * `input`            - Input can be either an `Enumerable` or a function which accepts `Collectable`.
                           1. input as Enumerable:
                           ```elixir
                           # List
                           Exile.stream!(~w(bc -q), input: ["1+1\n", "2*2\n"]) |> Enum.to_list()

                           # Stream
                           Exile.stream!(~w(cat), input: File.stream!("log.txt", [], 65536)) |> Enum.to_list()
                           ```
                           2. input as collectable:
                           If the input in a function with arity 1, Exile will call that function with a `Collectable` as the argument. The function must *push* input to this collectable. Return value of the function is ignored.
                           ```elixir
                           Exile.stream!(~w(cat), input: fn sink -> Enum.into(1..100, sink, &to_string/1) end)
                           |> Enum.to_list()
                           ```
                           By defaults no input will be given to the command
    * `exit_timeout`     - Duration to wait for external program to exit after completion before raising an error. Defaults to `:infinity`
    * `chunk_size`       - Size of each iodata chunk emitted by Enumerable stream. When set to `nil` the output is unbuffered and chunk size will be variable. Defaults to 65535
  All other options are passed to `Exile.Process.start_link/3`

  ### Examples

  ``` elixir
  Exile.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65535))
  |> Stream.into(File.stream!("music.mp3"))
  |> Stream.run()
  ```
  """
  def stream!(cmd_with_args, opts \\ []) do
    Exile.Stream.__build__(cmd_with_args, opts)
  end
end
