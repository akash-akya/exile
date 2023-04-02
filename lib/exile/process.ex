defmodule Exile.Process do
  @moduledoc """
  GenServer which wraps spawned external command.

  `Exile.stream!/1` should be preferred over using this. Use this only
  if you need more control over the life-cycle of IO streams and OS
  process.

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

  @default_opts [env: [], enable_stderr: false]
  @default_buffer_size 65_535
  @os_signal_timeout 1000

  @doc """
  Starts `Exile.Process`

  Starts external program using `cmd_with_args` with options `opts`

  `cmd_with_args` must be a list containing command with arguments. example: `["cat", "file.txt"]`.

  ### Options
    * `cd`   -  the directory to run the command in
    * `env`  -  a list of tuples containing environment key-value. These can be accessed in the external program
    * `enable_stderr`  -  when set to true, Exile connects stderr pipe for the consumption. Defaults to false. Note that when set to true stderr must be consumed to avoid external program from blocking
  """
  @spec start_link(nonempty_list(String.t()),
          cd: String.t(),
          env: [{String.t(), String.t()}],
          enable_stderr: boolean()
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
  Closes external program's standard input pipe (stdin)
  """
  @spec close_stdin(t) :: :ok | {:error, any()}
  def close_stdin(process) do
    GenServer.call(process.pid, {:close_pipe, :stdin}, :infinity)
  end

  @doc """
  Closes external program's standard output pipe (stdout)
  """
  @spec close_stdout(t) :: :ok | {:error, any()}
  def close_stdout(process) do
    GenServer.call(process.pid, {:close_pipe, :stdout}, :infinity)
  end

  @doc """
  Closes external program's standard error pipe (stderr)
  """
  @spec close_stderr(t) :: :ok | {:error, any()}
  def close_stderr(process) do
    GenServer.call(process.pid, {:close_pipe, :stderr}, :infinity)
  end

  @doc """
  Writes iodata `data` to program's standard input pipe

  This blocks when the pipe is full
  """
  @spec write(t, binary) :: :ok | {:error, any()}
  def write(process, iodata) do
    binary = IO.iodata_to_binary(iodata)
    GenServer.call(process.pid, {:write_stdin, binary}, :infinity)
  end

  @doc """
  Returns bytes from executed command's stdout with maximum size `max_size`.

  Blocks if no bytes are written to stdout yet. And returns as soon as bytes are available
  """
  @spec read(t, pos_integer()) :: {:ok, iodata} | :eof | {:error, any()}
  def read(process, max_size \\ @default_buffer_size)
      when is_integer(max_size) and max_size > 0 do
    GenServer.call(process.pid, {:read_stdout, max_size}, :infinity)
  end

  @doc """
  Returns bytes from executed command's stderr with maximum size `max_size`.

  Blocks if no bytes are written to stderr yet. And returns as soon as bytes are available
  """
  @spec read_stderr(t, pos_integer()) :: {:ok, iodata} | :eof | {:error, any()}
  def read_stderr(process, size \\ @default_buffer_size) when is_integer(size) and size > 0 do
    GenServer.call(process.pid, {:read_stderr, size}, :infinity)
  end

  @doc """
  Returns bytes from either stdout or stderr with maximum size `max_size` whichever is available.

  Blocks if no bytes are written to stdout/stderr yet. And returns as soon as bytes are available
  """
  @spec read_any(t, pos_integer()) ::
          {:ok, {:stdout, iodata}} | {:ok, {:stderr, iodata}} | :eof | {:error, any()}
  def read_any(process, size \\ @default_buffer_size) when is_integer(size) and size > 0 do
    GenServer.call(process.pid, {:read_stdout_or_stderr, size}, :infinity)
  end

  @spec change_pipe_owner(t, pipe_name, pid) :: :ok | {:error, any()}
  def change_pipe_owner(process, pipe_name, target_owner_pid) do
    GenServer.call(
      process.pid,
      {:change_pipe_owner, pipe_name, target_owner_pid},
      :infinity
    )
  end

  @doc """
  Sends signal to external program
  """
  @spec kill(t, :sigkill | :sigterm) :: :ok
  def kill(process, signal) when signal in [:sigkill, :sigterm] do
    GenServer.call(process.pid, {:kill, signal}, :infinity)
  end

  @doc """
  Waits for the program to terminate.

  If the program terminates before timeout, it returns `{:ok, exit_status}`
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
  """
  @spec os_pid(t) :: pos_integer()
  def os_pid(process) do
    GenServer.call(process.pid, :os_pid, :infinity)
  end

  ## Server

  @impl true
  def init(args) do
    {enable_stderr, args} = Map.pop(args, :enable_stderr)
    {owner, args} = Map.pop!(args, :owner)
    {exit_ref, args} = Map.pop!(args, :exit_ref)

    state = %State{
      args: args,
      owner: owner,
      status: :init,
      enable_stderr: enable_stderr,
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
    } = Exec.start(state.args, state.enable_stderr)

    stderr =
      if state.enable_stderr do
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
