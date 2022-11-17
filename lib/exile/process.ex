defmodule Exile.Process do
  @moduledoc """
  GenServer which wraps spawned external command.

  `Exile.stream!/1` should be preferred over using this. Use this only if you need more control over the life-cycle of IO streams and OS process.

  ## Comparison with Port

    * it is demand driven. User explicitly has to `read` the command output, and the progress of the external command is controlled using OS pipes. Exile never load more output than we can consume, so we should never experience memory issues
    * it can close stdin while consuming output
    * tries to handle zombie process by attempting to cleanup external process. Note that there is no middleware involved with exile so it is still possbile to endup with zombie process.
    * selectively consume stdout and stderr streams

  Internally Exile uses non-blocking asynchronous system calls to interact with the external process. It does not use port's message based communication, instead uses raw stdio and NIF. Uses asynchronous system calls for IO. Most of the system calls are non-blocking, so it should not block the beam schedulers. Make use of dirty-schedulers for IO
  """

  use GenServer

  alias __MODULE__
  alias Exile.ProcessNif, as: Nif
  require Logger

  defstruct [
    :args,
    :errno,
    :port,
    :socket_path,
    :stdin,
    :stdout,
    :stderr,
    :status,
    :use_stderr,
    :await,
    :read_stdout,
    :read_stderr,
    :read_any,
    :write_stdin
  ]

  defmodule Pending do
    @moduledoc false
    defstruct bin: [], size: 0, client_pid: nil
  end

  defmodule Error do
    defexception [:message]
  end

  @default_opts [env: [], use_stderr: false]
  @default_buffer_size 65535

  @doc """
  Starts `Exile.ProcessServer`

  Starts external program using `cmd_with_args` with options `opts`

  `cmd_with_args` must be a list containing command with arguments. example: `["cat", "file.txt"]`.

  ### Options
    * `cd`   -  the directory to run the command in
    * `env`  -  a list of tuples containing environment key-value. These can be accessed in the external program
    * `use_stderr`  -  when set to true, exile connects stderr stream for the consumption. Defaults to false. Note that when set to true stderr must be consumed to avoid external program from blocking
  """
  @type process :: pid
  @spec start_link(nonempty_list(String.t()),
          cd: String.t(),
          env: [{String.t(), String.t()}],
          use_stderr: boolean()
        ) :: {:ok, process} | {:error, any()}
  def start_link(cmd_with_args, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    with {:ok, args} <- normalize_args(cmd_with_args, opts) do
      GenServer.start(__MODULE__, args)
    end
  end

  @doc """
  Closes external program's input stream
  """
  @spec close_stdin(process) :: :ok | {:error, any()}
  def close_stdin(process) do
    GenServer.call(process, :close_stdin, :infinity)
  end

  @doc """
  Writes iodata `data` to program's input streams

  This blocks when the pipe is full
  """
  @spec write(process, binary) :: :ok | {:error, any()}
  def write(process, iodata) do
    GenServer.call(process, {:write_stdin, IO.iodata_to_binary(iodata)}, :infinity)
  end

  @doc """
  Returns bytes from executed command's stdout stream with maximum size `max_size`.

  Blocks if no bytes are written to stdout stream yet. And returns as soon as bytes are availble
  """
  @spec read(process, pos_integer()) :: {:ok, iodata} | :eof | {:error, any()}
  def read(process, max_size \\ @default_buffer_size)
      when is_integer(max_size) and max_size > 0 do
    GenServer.call(process, {:read_stdout, max_size}, :infinity)
  end

  @doc """
  Returns bytes from executed command's stderr stream with maximum size `max_size`.

  Blocks if no bytes are written to stdout stream yet. And returns as soon as bytes are availble
  """
  @spec read_stderr(process, pos_integer()) :: {:ok, iodata} | :eof | {:error, any()}
  def read_stderr(process, size \\ @default_buffer_size) when is_integer(size) and size > 0 do
    GenServer.call(process, {:read_stderr, size}, :infinity)
  end

  @doc """
  Returns bytes from either stdout or stderr stream with maximum size `max_size` whichever is availble.

  Blocks if no bytes are written to stdout/stderr stream yet. And returns as soon as bytes are availble
  """
  @spec read_any(process, pos_integer()) ::
          {:ok, {:stdout, iodata}} | {:ok, {:stderr, iodata}} | :eof | {:error, any()}
  def read_any(process, size \\ @default_buffer_size) when is_integer(size) and size > 0 do
    GenServer.call(process, {:read_any, size}, :infinity)
  end

  @doc """
  Sends signal to external program
  """
  @spec kill(process, :sigkill | :sigterm) :: :ok
  def kill(process, signal) when signal in [:sigkill, :sigterm] do
    GenServer.call(process, {:kill, signal}, :infinity)
  end

  @doc """
  Waits for the program to terminate.

  If the program terminates before timeout, it returns `{:ok, exit_status}` else returns `:timeout`
  """
  @spec await_exit(process, timeout: timeout()) :: {:ok, integer()} | :timeout
  def await_exit(process, timeout \\ :infinity) do
    GenServer.call(process, {:await_exit, timeout}, :infinity)
  end

  @doc """
  Returns OS pid of the command
  """
  @spec os_pid(process) :: pos_integer()
  def os_pid(process) do
    GenServer.call(process, :os_pid, :infinity)
  end

  @doc """
  Stops the exile process, external program will be terminated in the background
  """
  @spec stop(process) :: :ok
  def stop(process), do: GenServer.call(process, :stop, :infinity)

  ## Server

  def init(args) do
    {use_stderr, args} = Map.pop(args, :use_stderr)

    state = %__MODULE__{
      args: args,
      errno: nil,
      status: :init,
      await: %{},
      use_stderr: use_stderr,
      read_stdout: %Pending{},
      read_stderr: %Pending{},
      read_any: %Pending{},
      write_stdin: %Pending{}
    }

    {:ok, state, {:continue, nil}}
  end

  def handle_continue(nil, state) do
    Elixir.Process.flag(:trap_exit, true)
    {:noreply, start_process(state)}
  end

  def handle_call(:stop, _from, state) do
    # TODO: pending write and read should receive "stopped" return
    # value instead of exit signal
    {:stop, :normal, :ok, state}
  end

  def handle_call(:close_stdin, _from, state) do
    case state.status do
      {:exit, _} -> {:reply, :ok, state}
      _ -> do_close(state, :stdin)
    end
  end

  def handle_call({:await_exit, _}, _from, %{status: {:exit, status}} = state) do
    {:reply, {:ok, {:exit, status}}, state}
  end

  def handle_call({:await_exit, timeout}, from, %{status: :start} = state) do
    tref =
      if timeout != :infinity do
        Elixir.Process.send_after(self(), {:await_exit_timeout, from}, timeout)
      else
        nil
      end

    {:noreply, %Process{state | await: Map.put(state.await, from, tref)}}
  end

  def handle_call({:read_stdout, size}, from, state) do
    case can_read?(state, :stdout) do
      :ok ->
        pending = %Pending{size: size, client_pid: from}
        do_read_stdout(%Process{state | read_stdout: pending})

      error ->
        GenServer.reply(from, error)
        {:noreply, state}
    end
  end

  def handle_call({:read_stderr, size}, from, state) do
    case can_read?(state, :stderr) do
      :ok ->
        pending = %Pending{size: size, client_pid: from}
        do_read_stderr(%Process{state | read_stderr: pending})

      error ->
        GenServer.reply(from, error)
        {:noreply, state}
    end
  end

  def handle_call({:read_any, size}, from, state) do
    case can_read?(state, :any) do
      :ok ->
        pending = %Pending{size: size, client_pid: from}
        do_read_any(%Process{state | read_any: pending})

      error ->
        GenServer.reply(from, error)
        {:noreply, state}
    end
  end

  def handle_call(_, _from, %{status: {:exit, status}} = state) do
    {:reply, {:error, {:exit, status}}, state}
  end

  def handle_call({:write_stdin, binary}, from, state) do
    cond do
      !is_binary(binary) ->
        {:reply, {:error, :not_binary}, state}

      state.write_stdin.client_pid ->
        {:reply, {:error, :write_stdin}, state}

      true ->
        pending = %Pending{bin: binary, client_pid: from}
        do_write(%Process{state | write_stdin: pending})
    end
  end

  def handle_call(:os_pid, _from, state) do
    case Port.info(state.port, :os_pid) do
      {:os_pid, os_pid} ->
        {:reply, {:ok, os_pid}, state}

      :undefined ->
        Logger.debug("Process not alive")
        {:reply, :undefined, state}
    end
  end

  def handle_call({:kill, signal}, _from, state) do
    {:reply, signal(state.port, signal), state}
  end

  def handle_info({:await_exit_timeout, from}, state) do
    GenServer.reply(from, :timeout)
    {:noreply, %Process{state | await: Map.delete(state.await, from)}}
  end

  def handle_info({:select, _write_resource, _ref, :ready_output}, state), do: do_write(state)

  def handle_info({:select, read_resource, _ref, :ready_input}, state) do
    cond do
      state.read_any.client_pid ->
        stream =
          cond do
            read_resource == state.stdout -> :stdout
            read_resource == state.stderr -> :stderr
          end

        do_read_any(state, stream)

      state.read_stdout.client_pid && read_resource == state.stdout ->
        do_read_stdout(state)

      state.read_stderr.client_pid && read_resource == state.stderr ->
        do_read_stderr(state)

      true ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, exit_status}}, %{port: port} = state),
    do: handle_port_exit(exit_status, state)

  def handle_info({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, _, reason}, state), do: {:stop, reason, state}

  defp handle_port_exit(exit_status, state) do
    Enum.each(state.await, fn {from, tref} ->
      GenServer.reply(from, {:ok, {:exit, exit_status}})

      if tref do
        Elixir.Process.cancel_timer(tref)
      end
    end)

    {:noreply, %Process{state | status: {:exit, exit_status}, await: %{}}}
  end

  defmacrop eof, do: {:ok, <<>>}
  defmacrop eagain, do: {:error, :eagain}

  defp do_write(%Process{write_stdin: %Pending{bin: <<>>}} = state) do
    reply_action(state, :write_stdin, :ok)
  end

  defp do_write(%Process{write_stdin: pending} = state) do
    bin_size = byte_size(pending.bin)

    case Nif.nif_write(state.stdin, pending.bin) do
      {:ok, size} when size < bin_size ->
        binary = binary_part(pending.bin, size, bin_size - size)
        noreply_action(%{state | write_stdin: %Pending{pending | bin: binary}})

      {:ok, _size} ->
        reply_action(state, :write_stdin, :ok)

      eagain() ->
        noreply_action(state)

      {:error, errno} ->
        reply_action(%Process{state | errno: errno}, :write_stdin, {:error, errno})
    end
  end

  defp do_read_stdout(%Process{read_stdout: pending} = state) do
    case Nif.nif_read(state.stdout, pending.size) do
      eof() ->
        reply_action(state, :read_stdout, :eof)

      {:ok, binary} ->
        reply_action(state, :read_stdout, {:ok, binary})

      eagain() ->
        noreply_action(state)

      {:error, errno} ->
        reply_action(%Process{state | errno: errno}, :read_stdout, {:error, errno})
    end
  end

  defp do_read_stderr(%Process{read_stderr: pending} = state) do
    case Nif.nif_read(state.stderr, pending.size) do
      eof() ->
        reply_action(state, :read_stderr, :eof)

      {:ok, binary} ->
        reply_action(state, :read_stderr, {:ok, binary})

      eagain() ->
        noreply_action(state)

      {:error, errno} ->
        reply_action(%Process{state | errno: errno}, :read_stderr, {:error, errno})
    end
  end

  defp do_read_any(state, stream_hint \\ :stdout) do
    %Process{read_any: pending, use_stderr: use_stderr} = state

    other_stream =
      case stream_hint do
        :stdout -> :stderr
        :stderr -> :stdout
      end

    case Nif.nif_read(stream_fd(state, stream_hint), pending.size) do
      ret when ret in [eof(), eagain()] and use_stderr == true ->
        case {ret, Nif.nif_read(stream_fd(state, other_stream), pending.size)} do
          {eof(), eof()} ->
            reply_action(state, :read_any, :eof)

          {_, {:ok, binary}} ->
            reply_action(state, :read_any, {:ok, {other_stream, binary}})

          {_, eagain()} ->
            noreply_action(state)

          {_, {:error, errno}} ->
            reply_action(%Process{state | errno: errno}, :read_any, {:error, errno})
        end

      eof() ->
        reply_action(state, :read_any, :eof)

      {:ok, binary} ->
        reply_action(state, :read_any, {:ok, {stream_hint, binary}})

      eagain() ->
        noreply_action(state)

      {:error, errno} ->
        reply_action(%Process{state | errno: errno}, :read_any, {:error, errno})
    end
  end

  defp do_close(state, stream) do
    ret = Nif.nif_close(stream_fd(state, stream))
    {:reply, ret, state}
  end

  defp stream_fd(state, stream) do
    case stream do
      :stdin -> state.stdin
      :stdout -> state.stdout
      :stderr -> state.stderr
    end
  end

  defp can_read?(state, :stdout) do
    cond do
      state.read_stdout.client_pid ->
        {:error, :pending_stdout_read}

      true ->
        :ok
    end
  end

  defp can_read?(state, :stderr) do
    cond do
      !state.use_stderr ->
        {:error, :cannot_read_stderr}

      state.read_stderr.client_pid ->
        {:error, :pending_stderr_read}

      true ->
        :ok
    end
  end

  defp can_read?(state, :any) do
    with :ok <- can_read?(state, :stdout) do
      if state.use_stderr do
        can_read?(state, :stderr)
      else
        :ok
      end
    end
  end

  defp signal(port, sig) when sig in [:sigkill, :sigterm] do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> Nif.nif_kill(os_pid, sig)
      :undefined -> {:error, :process_not_alive}
    end
  end

  @spawner_path :filename.join(:code.priv_dir(:exile), "spawner")

  defp start_process(state) do
    %{args: %{cmd_with_args: cmd_with_args, cd: cd, env: env}, use_stderr: use_stderr} = state

    socket_path = socket_path()
    {:ok, sock} = :socket.open(:local, :stream, :default)

    try do
      :ok = socket_bind(sock, socket_path)
      :ok = :socket.listen(sock)

      spawner_cmdline_args = [socket_path, to_string(use_stderr) | cmd_with_args]

      port_opts =
        [:nouse_stdio, :exit_status, :binary, args: spawner_cmdline_args] ++
          prune_nils(env: env, cd: cd)

      port = Port.open({:spawn_executable, @spawner_path}, port_opts)

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      Exile.Watcher.watch(self(), os_pid, socket_path)

      {stdin, stdout, stderr} = receive_fds(sock, state.use_stderr)

      %Process{
        state
        | port: port,
          status: :start,
          socket_path: socket_path,
          stdin: stdin,
          stdout: stdout,
          stderr: stderr
      }
    after
      :socket.close(sock)
    end
  end

  @socket_timeout 2000

  defp receive_fds(lsock, use_stderr) do
    {:ok, sock} = :socket.accept(lsock, @socket_timeout)

    try do
      {:ok, msg} = :socket.recvmsg(sock, @socket_timeout)
      %{ctrl: [%{data: data, level: :socket, type: :rights}]} = msg

      <<stdin_fd::native-32, stdout_fd::native-32, stderr_fd::native-32, _::binary>> = data

      {:ok, stdout} = Nif.nif_create_fd(stdout_fd)
      {:ok, stdin} = Nif.nif_create_fd(stdin_fd)

      {:ok, stderr} =
        if use_stderr do
          Nif.nif_create_fd(stderr_fd)
        else
          {:ok, nil}
        end

      {stdin, stdout, stderr}
    after
      :socket.close(sock)
    end
  end

  defp socket_bind(sock, path) do
    case :socket.bind(sock, %{family: :local, path: path}) do
      :ok -> :ok
      # for OTP version <= 24 compatibility
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp socket_path do
    str = :crypto.strong_rand_bytes(16) |> Base.url_encode64() |> binary_part(0, 16)
    path = Path.join(System.tmp_dir!(), str)
    _ = :file.delete(path)
    path
  end

  defp prune_nils(kv) do
    Enum.reject(kv, fn {_, v} -> is_nil(v) end)
  end

  defp reply_action(state, action, return_value) do
    pending = Map.fetch!(state, action)

    :ok = GenServer.reply(pending.client_pid, return_value)
    {:noreply, Map.put(state, action, %Pending{})}
  end

  defp noreply_action(state) do
    {:noreply, state}
  end

  defp normalize_cmd(arg) do
    case arg do
      [cmd | _] when is_binary(cmd) ->
        path = System.find_executable(cmd)

        if path do
          {:ok, to_charlist(path)}
        else
          {:error, "command not found: #{inspect(cmd)}"}
        end

      _ ->
        {:error, "`cmd_with_args` must be a list of strings, Please check the documentation"}
    end
  end

  defp normalize_cmd_args([_ | args]) do
    if is_list(args) && Enum.all?(args, &is_binary/1) do
      {:ok, Enum.map(args, &to_charlist/1)}
    else
      {:error, "command arguments must be list of strings. #{inspect(args)}"}
    end
  end

  defp normalize_cd(cd) do
    case cd do
      nil ->
        {:ok, ''}

      cd when is_binary(cd) ->
        if File.exists?(cd) && File.dir?(cd) do
          {:ok, to_charlist(cd)}
        else
          {:error, "`:cd` must be valid directory path"}
        end

      _ ->
        {:error, "`:cd` must be a binary string"}
    end
  end

  defp normalize_env(env) do
    case env do
      nil ->
        {:ok, []}

      env when is_list(env) or is_map(env) ->
        env =
          Enum.map(env, fn {key, value} ->
            {to_charlist(key), to_charlist(value)}
          end)

        {:ok, env}

      _ ->
        {:error, "`:env` must be a map or list of `{string, string}`"}
    end
  end

  defp normalize_use_stderr(use_stderr) do
    case use_stderr do
      nil ->
        {:ok, false}

      use_stderr when is_boolean(use_stderr) ->
        {:ok, use_stderr}

      _ ->
        {:error, ":use_stderr must be a boolean"}
    end
  end

  defp validate_opts_fields(opts) do
    {_, additional_opts} = Keyword.split(opts, [:cd, :env, :use_stderr])

    if Enum.empty?(additional_opts) do
      :ok
    else
      {:error, "invalid opts: #{inspect(additional_opts)}"}
    end
  end

  defp normalize_args(cmd_with_args, opts) do
    with {:ok, cmd} <- normalize_cmd(cmd_with_args),
         {:ok, args} <- normalize_cmd_args(cmd_with_args),
         :ok <- validate_opts_fields(opts),
         {:ok, cd} <- normalize_cd(opts[:cd]),
         {:ok, use_stderr} <- normalize_use_stderr(opts[:use_stderr]),
         {:ok, env} <- normalize_env(opts[:env]) do
      {:ok, %{cmd_with_args: [cmd | args], cd: cd, env: env, use_stderr: use_stderr}}
    end
  end
end
