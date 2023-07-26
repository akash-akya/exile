defmodule Exile.Process do
  @moduledoc ~S"""
  GenServer which wraps spawned external command.

  Use `Exile.stream!/1` over using this. Use this only if you are
  familiar with life-cycle and need more control of the IO streams
  and OS process.

  ## Comparison with Port

    * it is demand driven. User explicitly has to `read` the command
  output, and the progress of the external command is controlled
  using OS pipes. Exile never load more output than we can consume,
  so we should never experience memory issues

    * it can close stdin while consuming output

    * tries to handle zombie process by attempting to cleanup
  external process. Note that there is no middleware involved
  with exile so it is still possible to endup with zombie process.

    * selectively consume stdout and stderr

  Internally Exile uses non-blocking asynchronous system calls
  to interact with the external process. It does not use port's
  message based communication, instead uses raw stdio and NIF.
  Uses asynchronous system calls for IO. Most of the system
  calls are non-blocking, so it should not block the beam
  schedulers. Make use of dirty-schedulers for IO

  ## Introduction

  `Exile.Process` is a process based wrapper around the external
  process. It is similar to `port` as an entity but the interface is
  different. All communication with the external process must happen
  via `Exile.Process` interface.

  Exile process life-cycle tied to external process and owners. All
  system resources such are open file-descriptors, external process
  are cleaned up when the `Exile.Process` dies.

  ### Owner

  Each `Exile.Process` has an owner. And it will be the process which
  created it (via `Exile.Process.start_link/2`). Process owner can not
  be changed.

  Owner process will be linked to the `Exile.Process`. So when the
  exile process is dies abnormally the owner will be killed too or
  visa-versa. Owner process should avoid trapping the exit signal, if
  you want avoid the caller getting killed, create a separate process
  as owner to run the command and monitor that process.

  Only owner can get the exit status of the command, using
  `Exile.Process.await_exit/2`. All exile processes **MUST** be
  awaited.  Exit status or reason is **ALWAYS** sent to the owner. It
  is similar to [`Task`](https://hexdocs.pm/elixir/Task.html). If the
  owner exit without `await_exit`, the exile process will be killed,
  but if the owner continue without `await_exit` then the exile
  process will linger around till the process exit.

  ```
  iex> alias Exile.Process
  iex> {:ok, p} = Process.start_link(~w(echo hello))
  iex> Process.read(p, 100)
  {:ok, "hello\n"}
  iex> Process.read(p, 100) # read till we get :eof
  :eof
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  ### Pipe & Pipe Owner

  Standard IO pipes/channels/streams of the external process such as
  STDIN, STDOUT, STDERR are called as Pipes. User can either write or
  read data from pipes.

  Each pipe has an owner process and only that process can write or
  read from the exile process. By default the process who created the
  exile process is the owner of all the pipes. Pipe owner can be
  changed using `Exile.Process.change_pipe_owner/3`.

  Pipe owner is monitored and the pipes are closed automatically when
  the pipe owner exit. Pipe Owner can close the pipe early using
  `Exile.Process.close_stdin/1` etc.

  `Exile.Process.await_exit/2` closes all of the caller owned pipes by
  default.

  ```
  iex> {:ok, p} = Process.start_link(~w(cat))
  iex> writer = Task.async(fn ->
  ...>   :ok = Process.change_pipe_owner(p, :stdin, self())
  ...>   Process.write(p, "Hello World")
  ...> end)
  iex> Task.await(writer)
  :ok
  iex> Process.read(p, 100)
  {:ok, "Hello World"}
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  ### Pipe Operations

  Pipe owner can read or write date to the owned pipe. `:stderr` by
  default is connected to console, data written to stderr will appear on
  the console. You can enable reading stderr by passing `stderr: :consume`
  during process creation.

  Special function `Exile.Process.read_any/2` can be used to read
  from either stdout or stderr whichever has the data available.

  All Pipe operations blocks the caller to have blocking as natural
  back-pressure and to make the API simple. This is an important
  feature of Exile, that is the ability to block caller when the stdio
  buffer is full, exactly similar to how programs works on the shell
  with pipes between then `cat larg-file | grep "foo"`. Internally it
  does not block the Exile process or VM (which is typically the case
  with NIF calls). Because of this user can make concurrent read,
  write to different pipes from separate processes. Internally Exile
  uses asynchronous IO APIs to avoid blocking of VM or VM process.

  Reading from stderr

  ```
  # write "Hello" to stdout and "World" to stderr
  iex> script = Enum.join(["echo Hello", "echo World >&2"], "\n")
  iex> {:ok, p} = Process.start_link(["sh", "-c", script], stderr: :consume)
  iex> Process.read(p, 100)
  {:ok, "Hello\n"}
  iex> Process.read_stderr(p, 100)
  {:ok, "World\n"}
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  Reading using `read_any`

  ```
  # write "Hello" to stdout and "World" to stderr
  iex> script = Enum.join(["echo Hello", "echo World >&2"], "\n")
  iex> {:ok, p} = Process.start_link(["sh", "-c", script], stderr: :consume)
  iex> Process.read_any(p)
  {:ok, {:stdout, "Hello\n"}}
  iex> Process.read_any(p)
  {:ok, {:stderr, "World\n"}}
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  ### Process Termination

  When owner does (normally or abnormally) the Exile process always
  terminated irrespective of pipe status or process status. External
  process get a chance to terminate gracefully, if that fail it will
  be killed.

  If owner calls `await_exit` then the owner owned pipes are closed
  and we wait for external process to terminate, if the process
  already terminated then call returns immediately with exit
  status. Else command will be attempted to stop gracefully following
  the exit sequence based on the timeout value (5s by default).

  If owner calls `await_exit` with `timeout` as `:infinity` then
  Exile does not attempt to forcefully stop the external command and
  wait for command to exit on itself. The `await_exit` call can be blocked
  indefinitely waiting for external process to terminate.

  If external process exit on its own, exit status is collected and
  Exile process will wait for owner to close pipes. Most commands exit
  with pipes are closed, so just ensuring to close pipes when works is
  done should be enough.

  Example of process getting terminated by `SIGTERM` signal

  ```
  # sleep command does not watch for stdin or stdout, so closing the
  # pipe does not terminate the sleep command.
  iex> {:ok, p} = Process.start_link(~w(sleep 100000000)) # sleep indefinitely
  iex> Process.await_exit(p, 100) # ensure `await_exit` finish within `100ms`. By default it waits for 5s
  {:ok, 143} # 143 is the exit status when command exit due to SIGTERM
  ```

  ## Examples

  Run a command without any input or output

  ```
  iex> {:ok, p} = Process.start_link(["sh", "-c", "exit 1"])
  iex> Process.await_exit(p)
  {:ok, 1}
  ```

  Single process reading and writing to the command

  ```
  # bc is a calculator, which reads from stdin and writes output to stdout
  iex> {:ok, p} = Process.start_link(~w(bc))
  iex> Process.write(p, "1 + 1\n") # there must be new-line to indicate the end of the input line
  :ok
  iex> Process.read(p)
  {:ok, "2\n"}
  iex> Process.write(p, "2 * 10 + 1\n")
  :ok
  iex> Process.read(p)
  {:ok, "21\n"}
  # We must close stdin to signal the `bc` command that we are done.
  # since `await_exit` implicitly closes the pipes, in this case we don't have to
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  Running a command which flush the output on stdin close. This is not
  supported by Erlang/Elixir ports.

  ```
  # `base64` command reads all input and writes encoded output when stdin is closed.
  iex> {:ok, p} = Process.start_link(~w(base64))
  iex> Process.write(p, "abcdef")
  :ok
  iex> Process.close_stdin(p) # we can selectively close stdin and read all output
  :ok
  iex> Process.read(p)
  {:ok, "YWJjZGVm\n"}
  iex> Process.read(p) # typically it is better to read till we receive :eof when we are not sure how big the output data size is
  :eof
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  Read and write to pipes in separate processes

  ```
  iex> {:ok, p} = Process.start_link(~w(cat))
  iex> writer = Task.async(fn ->
  ...>   :ok = Process.change_pipe_owner(p, :stdin, self())
  ...>   Process.write(p, "Hello World")
  ...>   # no need to close the pipe explicitly here. Pipe will be closed automatically when process exit
  ...> end)
  iex> reader = Task.async(fn ->
  ...>   :ok = Process.change_pipe_owner(p, :stdout, self())
  ...>   Process.read(p)
  ...> end)
  iex> :timer.sleep(500) # wait for the reader and writer to change pipe owner, otherwise `await_exit` will close the pipes before we change pipe owner
  iex> Process.await_exit(p, :infinity) # let the reader and writer take indefinite time to finish
  {:ok, 0}
  iex> Task.await(writer)
  :ok
  iex> Task.await(reader)
  {:ok, "Hello World"}
  ```

  """

  use GenServer

  alias Exile.Process.Exec
  alias Exile.Process.Nif
  alias Exile.Process.Operations
  alias Exile.Process.Pipe
  alias Exile.Process.State

  require Logger

  defmodule Error do
    defexception [:message]
  end

  @type pipe_name :: :stdin | :stdout | :stderr

  @type t :: %__MODULE__{
          monitor_ref: reference(),
          exit_ref: reference(),
          pid: pid | nil,
          owner: pid
        }

  defstruct [:monitor_ref, :exit_ref, :pid, :owner]

  @type exit_status :: non_neg_integer

  @default_opts [env: [], stderr: :console]
  @default_buffer_size 65_535
  @os_signal_timeout 1000

  @doc """
  Starts `Exile.Process` server.

  Starts external program using `cmd_with_args` with options `opts`

  `cmd_with_args` must be a list containing command with arguments.
  example: `["cat", "file.txt"]`.

  ### Options

    * `cd`   -  the directory to run the command in

    * `env`  -  a list of tuples containing environment key-value.
  These can be accessed in the external program

    * `stderr`  -  different ways to handle stderr stream.
  possible values `:console`, `:disable`, `:stream`.
        1. `:console`  -  stderr output is redirected to console (Default)
        2. `:disable`  -  stderr output is redirected `/dev/null` suppressing all output
        3. `:consume`  -  connects stderr for the consumption. When set to stream the output must be consumed to
  avoid external program from blocking.

  Caller of the process will be the owner owner of the Exile Process.
  And default owner of all opened pipes.

  Please check module documentation for more details
  """
  @spec start_link(nonempty_list(String.t()),
          cd: String.t(),
          env: [{String.t(), String.t()}],
          stderr: :console | :disable | :stream
        ) :: {:ok, t} | {:error, any()}
  def start_link(cmd_with_args, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    case Exec.normalize_exec_args(cmd_with_args, opts) do
      {:ok, args} ->
        owner = self()
        exit_ref = make_ref()
        args = Map.merge(args, %{owner: owner, exit_ref: exit_ref})
        {:ok, pid} = GenServer.start_link(__MODULE__, args)
        ref = Process.monitor(pid)

        process = %__MODULE__{
          pid: pid,
          monitor_ref: ref,
          exit_ref: exit_ref,
          owner: owner
        }

        {:ok, process}

      error ->
        error
    end
  end

  @doc """
  Closes external program's standard input pipe (stdin).

  Only owner of the pipe can close the pipe. This call will return
  immediately.
  """
  @spec close_stdin(t) :: :ok | {:error, :pipe_closed_or_invalid_caller} | {:error, any()}
  def close_stdin(process) do
    GenServer.call(process.pid, {:close_pipe, :stdin}, :infinity)
  end

  @doc """
  Closes external program's standard output pipe (stdout)

  Only owner of the pipe can close the pipe. This call will return
  immediately.
  """
  @spec close_stdout(t) :: :ok | {:error, any()}
  def close_stdout(process) do
    GenServer.call(process.pid, {:close_pipe, :stdout}, :infinity)
  end

  @doc """
  Closes external program's standard error pipe (stderr)

  Only owner of the pipe can close the pipe. This call will return
  immediately.
  """
  @spec close_stderr(t) :: :ok | {:error, any()}
  def close_stderr(process) do
    GenServer.call(process.pid, {:close_pipe, :stderr}, :infinity)
  end

  @doc """
  Writes iodata `data` to external program's standard input pipe.

  This call blocks when the pipe is full. Returns `:ok` when
  the complete data is written.
  """
  @spec write(t, binary) :: :ok | {:error, any()}
  def write(process, iodata) do
    binary = IO.iodata_to_binary(iodata)
    GenServer.call(process.pid, {:write_stdin, binary}, :infinity)
  end

  @doc """
  Returns bytes from executed command's stdout with maximum size `max_size`.

  Blocks if no data present in stdout pipe yet. And returns as soon as
  data of any size is available.

  Note that `max_size` is the maximum size of the returned data. But
  the returned data can be less than that depending on how the program
  flush the data etc.
  """
  @spec read(t, pos_integer()) :: {:ok, iodata} | :eof | {:error, any()}
  def read(process, max_size \\ @default_buffer_size)
      when is_integer(max_size) and max_size > 0 do
    GenServer.call(process.pid, {:read_stdout, max_size}, :infinity)
  end

  @doc """
  Returns bytes from executed command's stderr with maximum size `max_size`.
  Pipe must be enabled with `stderr: :consume` to read the data.

  Blocks if no bytes are written to stderr yet. And returns as soon as
  bytes are available

  Note that `max_size` is the maximum size of the returned data. But
  the returned data can be less than that depending on how the program
  flush the data etc.
  """
  @spec read_stderr(t, pos_integer()) :: {:ok, iodata} | :eof | {:error, any()}
  def read_stderr(process, size \\ @default_buffer_size) when is_integer(size) and size > 0 do
    GenServer.call(process.pid, {:read_stderr, size}, :infinity)
  end

  @doc """
  Returns bytes from either stdout or stderr with maximum size
  `max_size` whichever is available at that time.

  Blocks if no bytes are written to stdout or stderr yet. And returns
  as soon as data is available.

  Note that `max_size` is the maximum size of the returned data. But
  the returned data can be less than that depending on how the program
  flush the data etc.
  """
  @spec read_any(t, pos_integer()) ::
          {:ok, {:stdout, iodata}} | {:ok, {:stderr, iodata}} | :eof | {:error, any()}
  def read_any(process, size \\ @default_buffer_size) when is_integer(size) and size > 0 do
    GenServer.call(process.pid, {:read_stdout_or_stderr, size}, :infinity)
  end

  @doc """
  Changes the Pipe owner of the pipe to specified pid.

  Note that currently any process can change the pipe owner.

  For more details about Pipe Owner, please check module docs.
  """
  @spec change_pipe_owner(t, pipe_name, pid) :: :ok | {:error, any()}
  def change_pipe_owner(process, pipe_name, target_owner_pid) do
    GenServer.call(
      process.pid,
      {:change_pipe_owner, pipe_name, target_owner_pid},
      :infinity
    )
  end

  @doc """
  Sends an system signal to external program

  Note that `:sigkill` kills the program unconditionally.

  Avoid sending signals manually, use `await_exit` instead.
  """
  @spec kill(t, :sigkill | :sigterm) :: :ok
  def kill(process, signal) when signal in [:sigkill, :sigterm] do
    GenServer.call(process.pid, {:kill, signal}, :infinity)
  end

  @doc """
  Wait for the program to terminate and get exit status.

  **ONLY** the Process owner can call this function. And all Exile
  **process MUST** be awaited (Similar to Task).

  Exile first politely asks the program to terminate by closing the
  pipes owned by the process owner (by default process owner is the
  pipes owner). Most programs terminates when standard pipes are
  closed.

  If you have changed the pipe owner to other process, you have to
  close pipe yourself or wait for the program to exit.

  If the program fails to terminate within the timeout (default 5s)
  then the program will be killed using the exit sequence by sending
  `SIGTERM`, `SIGKILL` signals in sequence.

  When timeout is set to `:infinity` `await_exit` wait for the
  programs to terminate indefinitely.

  For more details check module documentation.
  """
  @spec await_exit(t, timeout :: timeout()) :: {:ok, exit_status}
  def await_exit(process, timeout \\ 5000) do
    %__MODULE__{
      monitor_ref: monitor_ref,
      exit_ref: exit_ref,
      owner: owner,
      pid: pid
    } = process

    if self() != owner do
      raise ArgumentError,
            "task #{inspect(process)} exit status can only be queried by owner but was queried from #{inspect(self())}"
    end

    graceful_exit_timeout =
      if timeout == :infinity do
        :infinity
      else
        # process exit steps should finish before receive timeout exceeds
        # receive timeout is max allowed time for the `await_exit` call to block
        max(0, timeout - 100)
      end

    :ok = GenServer.cast(pid, {:prepare_exit, owner, graceful_exit_timeout})

    receive do
      {^exit_ref, exit_status} ->
        Process.demonitor(monitor_ref, [:flush])
        exit_status

      {:DOWN, ^monitor_ref, _, _proc, reason} ->
        exit({reason, {__MODULE__, :await_exit, [process, timeout]}})
    after
      # ideally we should never this this case since the process must
      # be terminated before the timeout and we should have received
      # `DOWN` message
      timeout ->
        exit({:timeout, {__MODULE__, :await_exit, [process, timeout]}})
    end
  end

  @doc """
  Returns OS pid of the command

  This is meant only for debugging. Avoid interacting with the
  external process directly
  """
  @spec os_pid(t) :: pos_integer()
  def os_pid(process) do
    GenServer.call(process.pid, :os_pid, :infinity)
  end

  ## Server

  @impl true
  def init(args) do
    {stderr, args} = Map.pop(args, :stderr)
    {owner, args} = Map.pop!(args, :owner)
    {exit_ref, args} = Map.pop!(args, :exit_ref)

    state = %State{
      args: args,
      owner: owner,
      status: :init,
      stderr: stderr,
      operations: Operations.new(),
      exit_ref: exit_ref,
      monitor_ref: Process.monitor(owner)
    }

    {:ok, state, {:continue, nil}}
  end

  @impl true
  def handle_continue(nil, state) do
    {:noreply, exec(state)}
  end

  @impl true
  def handle_cast({:prepare_exit, caller, timeout}, state) do
    state =
      Enum.reduce(state.pipes, state, fn {_pipe_name, pipe}, state ->
        case Pipe.close(pipe, caller) do
          {:ok, pipe} ->
            {:ok, state} = State.put_pipe(state, pipe.name, pipe)
            state

          {:error, _} ->
            state
        end
      end)

    case maybe_shutdown(state) do
      {:stop, :normal, state} ->
        {:stop, :normal, state}

      {:noreply, state} ->
        if timeout == :infinity do
          {:noreply, state}
        else
          total_stages = 3
          stage_timeout = div(timeout, total_stages)
          handle_info({:prepare_exit, :normal_exit, stage_timeout}, state)
        end
    end
  end

  @impl true
  def handle_call({:change_pipe_owner, pipe_name, new_owner}, _from, state) do
    with {:ok, pipe} <- State.pipe(state, pipe_name),
         {:ok, new_pipe} <- Pipe.set_owner(pipe, new_owner),
         {:ok, state} <- State.put_pipe(state, pipe_name, new_pipe) do
      {:reply, :ok, state}
    else
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:close_pipe, pipe_name}, {caller, _} = from, state) do
    with {:ok, pipe} <- State.pipe(state, pipe_name),
         {:ok, new_pipe} <- Pipe.close(pipe, caller),
         :ok <- GenServer.reply(from, :ok),
         {:ok, new_state} <- State.put_pipe(state, pipe_name, new_pipe) do
      maybe_shutdown(new_state)
    else
      {:error, _} = ret ->
        {:reply, ret, state}
    end
  end

  def handle_call({:read_stdout, size}, from, state) do
    case Operations.read(state, {:read_stdout, from, size}) do
      {:noreply, state} ->
        {:noreply, state}

      ret ->
        {:reply, ret, state}
    end
  end

  def handle_call({:read_stderr, size}, from, state) do
    case Operations.read(state, {:read_stderr, from, size}) do
      {:noreply, state} ->
        {:noreply, state}

      ret ->
        {:reply, ret, state}
    end
  end

  def handle_call({:read_stdout_or_stderr, size}, from, state) do
    case Operations.read_any(state, {:read_stdout_or_stderr, from, size}) do
      {:noreply, state} ->
        {:noreply, state}

      ret ->
        {:reply, ret, state}
    end
  end

  def handle_call({:write_stdin, binary}, from, state) do
    case Operations.write(state, {:write_stdin, from, binary}) do
      {:noreply, state} ->
        {:noreply, state}

      ret ->
        {:reply, ret, state}
    end
  end

  def handle_call(:os_pid, _from, state) do
    case Port.info(state.port, :os_pid) do
      {:os_pid, os_pid} ->
        {:reply, {:ok, os_pid}, state}

      nil ->
        Logger.debug("Process not alive")
        {:reply, :undefined, state}
    end
  end

  def handle_call({:kill, signal}, _from, state) do
    {:reply, signal(state.port, signal), state}
  end

  @impl true
  def handle_info({:prepare_exit, current_stage, timeout}, %{status: status, port: port} = state) do
    cond do
      status != :running ->
        {:noreply, state}

      current_stage == :normal_exit ->
        Elixir.Process.send_after(self(), {:prepare_exit, :sigterm, timeout}, timeout)
        {:noreply, state}

      current_stage == :sigterm ->
        signal(port, :sigterm)
        Elixir.Process.send_after(self(), {:prepare_exit, :sigkill, timeout}, timeout)
        {:noreply, state}

      current_stage == :sigkill ->
        signal(port, :sigkill)
        Elixir.Process.send_after(self(), {:prepare_exit, :stop, timeout}, timeout)
        {:noreply, state}

      # this should never happen, since sigkill signal can not be ignored by the OS process
      current_stage == :stop ->
        {:stop, :sigkill_timeout, state}
    end
  end

  def handle_info({:select, write_resource, _ref, :ready_output}, state) do
    :stdin = State.pipe_name_for_fd(state, write_resource)

    with {:ok, {:write_stdin, from, _bin} = operation, state} <-
           State.pop_operation(state, :write_stdin) do
      case Operations.write(state, operation) do
        {:noreply, state} ->
          {:noreply, state}

        ret ->
          GenServer.reply(from, ret)
          {:noreply, state}
      end
    end
  end

  def handle_info({:select, read_resource, _ref, :ready_input}, state) do
    pipe_name = State.pipe_name_for_fd(state, read_resource)

    with {:ok, operation_name} <- Operations.match_pending_operation(state, pipe_name),
         {:ok, {_, from, _} = operation, state} <- State.pop_operation(state, operation_name) do
      ret =
        case operation_name do
          :read_stdout_or_stderr ->
            Operations.read_any(state, operation)

          name when name in [:read_stdout, :read_stderr] ->
            Operations.read(state, operation)
        end

      case ret do
        {:noreply, state} ->
          {:noreply, state}

        ret ->
          GenServer.reply(from, ret)
          {:noreply, state}
      end
    else
      {:error, _error} ->
        {:noreply, state}
    end
  end

  def handle_info({:stop, :sigterm}, state) do
    if state.status == :running do
      signal(state.port, :sigkill)
      Elixir.Process.send_after(self(), {:stop, :sigkill}, @os_signal_timeout)
    end

    {:noreply, state}
  end

  def handle_info({:stop, :sigkill}, state) do
    if state.status == :running do
      # this should never happen, since sigkill signal can not be handled
      {:stop, :sigkill_timeout, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, exit_status}}, %{port: port} = state) do
    send(state.owner, {state.exit_ref, {:ok, exit_status}})
    state = State.set_status(state, {:exit, exit_status})
    maybe_shutdown(state)
  end

  # we are only interested in Port exit signals
  def handle_info({:EXIT, port, reason}, %State{port: port} = state) when reason != :normal do
    send(state.owner, {state.exit_ref, {:error, reason}})
    state = State.set_status(state, {:exit, {:error, reason}})
    maybe_shutdown(state)
  end

  def handle_info({:EXIT, port, :normal}, %{port: port} = state) do
    maybe_shutdown(state)
  end

  # shutdown unconditionally when process owner exit normally.
  # Since Exile process is linked to the owner, in case of owner crash,
  # exile process will be killed by the VM.
  def handle_info(
        {:DOWN, owner_ref, :process, _pid, reason},
        %State{monitor_ref: owner_ref} = state
      ) do
    {:stop, reason, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      Enum.reduce(state.pipes, state, fn {_pipe_name, pipe}, state ->
        case Pipe.close(pipe, pid) do
          {:ok, pipe} ->
            {:ok, state} = State.put_pipe(state, pipe.name, pipe)
            state

          {:error, _} ->
            state
        end
      end)

    maybe_shutdown(state)
  end

  @type signal :: :sigkill | :sigterm

  @spec signal(port, signal) :: :ok | {:error, :invalid_signal} | {:error, :process_not_alive}
  defp signal(port, signal) do
    with true <- signal in [:sigkill, :sigterm],
         {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      Nif.nif_kill(os_pid, signal)
    else
      false ->
        {:error, :invalid_signal}

      nil ->
        {:error, :process_not_alive}
    end
  end

  @spec maybe_shutdown(State.t()) :: {:stop, :normal, State.t()} | {:noreply, State.t()}
  defp maybe_shutdown(state) do
    open_pipes_count =
      state.pipes
      |> Map.values()
      |> Enum.count(&Pipe.open?/1)

    if open_pipes_count == 0 && !(state.status in [:init, :running]) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @spec exec(State.t()) :: State.t()
  defp exec(state) do
    %{
      port: port,
      stdin: stdin_fd,
      stdout: stdout_fd,
      stderr: stderr_fd
    } = Exec.start(state.args, state.stderr)

    stderr =
      if state.stderr == :consume do
        Pipe.new(:stderr, stderr_fd, state.owner)
      else
        Pipe.new(:stderr)
      end

    %State{
      state
      | port: port,
        status: :running,
        pipes: %{
          stdin: Pipe.new(:stdin, stdin_fd, state.owner),
          stdout: Pipe.new(:stdout, stdout_fd, state.owner),
          stderr: stderr
        }
    }
  end
end
