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

    * `input` - Input can be either an `Enumerable` or a function which accepts `Collectable`.

      * Enumerable:

        ```
        # List
        Exile.stream!(~w(base64), input: ["hello", "world"]) |> Enum.to_list()
        # Stream
        Exile.stream!(~w(cat), input: File.stream!("log.txt", [], 65536)) |> Enum.to_list()
        ```

      * Collectable:

        If the input in a function with arity 1, Exile will call that function with a `Collectable` as the argument. The function must *push* input to this collectable. Return value of the function is ignored.

        ```
        Exile.stream!(~w(cat), input: fn sink -> Enum.into(1..100, sink, &to_string/1) end)
        |> Enum.to_list()
        ```

      By defaults no input will be given to the command

    * `exit_timeout` - Duration to wait for external program to exit after completion before raising an error. Defaults to `:infinity`

    * `chunk_size` - Size of each iodata chunk emitted by Enumerable stream. When set to `:unbuffered` the output is unbuffered and chunk size will be variable depending on the amount of data availble at that time. Defaults to 65535

  All other options are passed to `Exile.Process.start_link/3`

  ### Examples

  ```
  Exile.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65535))
  |> Stream.into(File.stream!("music.mp3"))
  |> Stream.run()
  ```
  """
  @type collectable_func() :: (Collectable.t() -> any())

  @spec stream!(nonempty_list(String.t()),
          input: Enum.t() | collectable_func(),
          exit_timeout: timeout(),
          chunk_size: pos_integer() | :unbuffered
        ) :: ExCmd.Stream.t()
  def stream!(cmd_with_args, opts \\ []) do
    Exile.Stream.__build__(cmd_with_args, opts)
  end
end
