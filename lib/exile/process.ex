defmodule Exile.Process do
  @moduledoc """
  GenServer which wraps spawned external command.

  One should use `Exile.stream!` over `Exile.Process`. stream internally manages this server for you. Use this only if you need more control over the  life-cycle OS process.

  ## Overview
  `Exile.Process` is an alternative primitive for Port. It has different interface and approach to running external programs to solve the issues associated with the ports.

  ### When compared to Port
    * it is demand driven. User explicitly has to `read` output of the command and the progress of the external command is controlled using OS pipes. so unlike Port, this never cause memory issues in beam by loading more than we can consume
    * it can close stdin of the program explicitly
    * does not create zombie process. It always tries to cleanup resources

  At high level it makes non-blocking asynchronous system calls to execute and interact with the external program. It completely bypasses beam implementation for the same using NIF. It uses `select()` system call for asynchronous IO. Most of the system calls are non-blocking, so it does not has adverse effect on scheduler. Issues such as "scheduler collapse".
  """

  alias Exile.ProcessNif, as: Nif
  require Logger
  use GenServer

  defmodule Error do
    defexception [:message]
  end

  alias Exile.Process.Error

  @default_opts [env: []]

  @doc """
  Starts `Exile.ProcessServer`

  Starts external program using `cmd_with_args` with options `opts`

  `cmd_with_args` must be a list containing command with arguments. example: `["cat", "file.txt"]`.

  ### Options
    * `cd`                -  the directory to run the command in
    * `env`               -  an enumerable of tuples containing environment key-value. These can be accessed in the external program
  """
  def start_link(cmd_with_args, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    with {:ok, args} <- normalize_args(cmd_with_args, opts) do
      GenServer.start(__MODULE__, args)
    end
  end

  def close_stdin(process) do
    GenServer.call(process, :close_stdin, :infinity)
  end

  def write(process, iodata) do
    GenServer.call(process, {:write, IO.iodata_to_binary(iodata)}, :infinity)
  end

  def read(process, size) when (is_integer(size) and size > 0) or size == :unbuffered do
    GenServer.call(process, {:read, size}, :infinity)
  end

  def read(process) do
    GenServer.call(process, {:read, :unbuffered}, :infinity)
  end

  def kill(process, signal) when signal in [:sigkill, :sigterm] do
    GenServer.call(process, {:kill, signal}, :infinity)
  end

  def await_exit(process, timeout \\ :infinity) do
    GenServer.call(process, {:await_exit, timeout}, :infinity)
  end

  def os_pid(process) do
    GenServer.call(process, :os_pid, :infinity)
  end

  def stop(process), do: GenServer.call(process, :stop, :infinity)

  ## Server

  defmodule Pending do
    defstruct bin: [], remaining: 0, client_pid: nil
  end

  defstruct [
    :args,
    :errno,
    :port,
    :socket_path,
    :stdin,
    :stdout,
    :context,
    :status,
    await: %{},
    pending_read: nil,
    pending_write: nil
  ]

  alias __MODULE__

  def init(args) do
    state = %__MODULE__{
      args: args,
      errno: nil,
      status: :init,
      await: %{},
      pending_read: %Pending{},
      pending_write: %Pending{}
    }

    {:ok, state, {:continue, nil}}
  end

  def handle_continue(nil, state) do
    Elixir.Process.flag(:trap_exit, true)

    %{cmd_with_args: cmd_with_args, cd: cd, env: env} = state.args
    socket_path = socket_path()

    uds = create_unix_domain_socket!(socket_path)

    port = exec(cmd_with_args, socket_path, env, cd)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Exile.Watcher.watch(self(), os_pid, socket_path)

    {write_fd, read_fd} = receive_file_descriptors!(uds)

    {:noreply,
     %Process{
       state
       | port: port,
         status: :start,
         socket_path: socket_path,
         stdin: read_fd,
         stdout: write_fd
     }}
  end

  def handle_call(:stop, _from, state) do
    # TODO: pending write and read should receive "stopped" return
    # value instead of exit signal
    case state.status do
      {:exit, _} -> :ok
      _ -> Port.close(state.port)
    end

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

  def handle_call(_, _from, %{status: {:exit, status}} = state) do
    {:reply, {:error, {:exit, status}}, state}
  end

  def handle_call({:write, binary}, from, state) do
    cond do
      !is_binary(binary) ->
        {:reply, {:error, :not_binary}, state}

      state.pending_write.client_pid ->
        {:reply, {:error, :pending_write}, state}

      true ->
        pending = %Pending{bin: binary, client_pid: from}
        do_write(%Process{state | pending_write: pending})
    end
  end

  def handle_call({:read, size}, from, state) do
    if state.pending_read.client_pid do
      {:reply, {:error, :pending_read}, state}
    else
      pending = %Pending{remaining: size, client_pid: from}
      do_read(%Process{state | pending_read: pending})
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

  def handle_info({:select, _read_resource, _ref, :ready_input}, state), do: do_read(state)

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

    {:noreply, %Process{state | status: {:exit, exit_status}}, await: %{}}
  end

  defp do_write(%Process{pending_write: %Pending{bin: <<>>}} = state) do
    GenServer.reply(state.pending_write.client_pid, :ok)
    {:noreply, %{state | pending_write: %Pending{}}}
  end

  defp do_write(%Process{pending_write: pending} = state) do
    case Nif.nif_write(state.stdin, pending.bin) do
      {:ok, size} ->
        if size < byte_size(pending.bin) do
          binary = binary_part(pending.bin, size, byte_size(pending.bin) - size)
          {:noreply, %{state | pending_write: %Pending{pending | bin: binary}}}
        else
          GenServer.reply(pending.client_pid, :ok)
          {:noreply, %{state | pending_write: %Pending{}}}
        end

      {:error, :eagain} ->
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(pending.client_pid, {:error, errno})
        {:noreply, %{state | errno: errno}}
    end
  end

  defp do_read(%Process{pending_read: %Pending{remaining: :unbuffered} = pending} = state) do
    case Nif.nif_read(state.stdout, -1) do
      {:ok, <<>>} ->
        GenServer.reply(pending.client_pid, {:eof, []})
        {:noreply, %Process{state | pending_read: %Pending{}}}

      {:ok, binary} ->
        GenServer.reply(pending.client_pid, {:ok, binary})
        {:noreply, %Process{state | pending_read: %Pending{}}}

      {:error, :eagain} ->
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(pending.client_pid, {:error, errno})
        {:noreply, %Process{state | pending_read: %Pending{}, errno: errno}}
    end
  end

  defp do_read(%Process{pending_read: pending} = state) do
    case Nif.nif_read(state.stdout, pending.remaining) do
      {:ok, <<>>} ->
        GenServer.reply(pending.client_pid, {:eof, pending.bin})
        {:noreply, %Process{state | pending_read: %Pending{}}}

      {:ok, binary} ->
        if byte_size(binary) < pending.remaining do
          pending = %Pending{
            pending
            | bin: [pending.bin | binary],
              remaining: pending.remaining - byte_size(binary)
          }

          {:noreply, %Process{state | pending_read: pending}}
        else
          GenServer.reply(pending.client_pid, {:ok, [state.pending_read.bin | binary]})
          {:noreply, %Process{state | pending_read: %Pending{}}}
        end

      {:error, :eagain} ->
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(pending.client_pid, {:error, errno})
        {:noreply, %{state | pending_read: %Pending{}, errno: errno}}
    end
  end

  defp do_close(state, type) do
    fd =
      if type == :stdin do
        state.stdin
      else
        state.stdout
      end

    case Nif.nif_close(fd) do
      :ok ->
        {:reply, :ok, state}

      {:error, errno} ->
        # FIXME: correct
        raise errno
        {:reply, {:error, errno}, %Process{state | errno: errno}}
    end
  end

  defp normalize_cmd(cmd) do
    path = System.find_executable(cmd)

    if path do
      {:ok, to_charlist(path)}
    else
      {:error, "command not found: #{inspect(cmd)}"}
    end
  end

  defp normalize_cmd(_cmd_with_args) do
    {:error, "`cmd_with_args` must be a list of strings, Please check the documentation"}
  end

  defp normalize_cmd_args([_ | args]) do
    if is_list(args) && Enum.all?(args, &is_binary/1) do
      {:ok, Enum.map(args, &to_charlist/1)}
    else
      {:error, "command arguments must be list of strings. #{inspect(args)}"}
    end
  end

  defp normalize_cd(nil), do: {:ok, ''}

  defp normalize_cd(cd) do
    if File.exists?(cd) && File.dir?(cd) do
      {:ok, to_charlist(cd)}
    else
      {:error, "`:cd` must be valid directory path"}
    end
  end

  defp normalize_env(nil), do: {:ok, []}

  defp normalize_env(env) do
    env =
      Enum.map(env, fn {key, value} ->
        {to_charlist(key), to_charlist(value)}
      end)

    {:ok, env}
  end

  defp validate_opts_fields(opts) do
    {_, additional_opts} = Keyword.split(opts, [:cd, :env])

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
         {:ok, env} <- normalize_env(opts[:env]) do
      {:ok, %{cmd_with_args: [cmd | args], cd: cd, env: env}}
    end
  end

  defp normalize_args(_, _), do: {:error, "invalid arguments"}

  @spawner_path :filename.join(:code.priv_dir(:exile), "spawner")

  defp exec(cmd_with_args, socket_path, env, cd) do
    opts = []
    opts = if cd, do: [{:cd, cd} | opts], else: []
    opts = if env, do: [{:env, env} | opts], else: opts

    opts =
      [
        :nouse_stdio,
        :exit_status,
        :binary,
        args: [socket_path | cmd_with_args]
      ] ++ opts

    Port.open({:spawn_executable, @spawner_path}, opts)
  end

  defp socket_path do
    str = :crypto.strong_rand_bytes(16) |> Base.url_encode64() |> binary_part(0, 16)
    path = Path.join(System.tmp_dir!(), str)
    _ = :file.delete(path)
    path
  end

  defp signal(port, sig) when sig in [:sigkill, :sigterm] do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> Nif.nif_kill(os_pid, sig)
      :undefined -> {:error, :process_not_alive}
    end
  end

  defp create_unix_domain_socket!(socket_path) do
    {:ok, uds} = :socket.open(:local, :stream, :default)
    {:ok, _} = :socket.bind(uds, %{family: :local, path: socket_path})
    :ok = :socket.listen(uds)
    uds
  end

  @socket_timeout 2000
  defp receive_file_descriptors!(uds) do
    with {:ok, sock} <- :socket.accept(uds, @socket_timeout),
         {:ok, msg} <- :socket.recvmsg(sock) do
      %{
        ctrl: [
          %{
            data: <<read_fd_int::native-32, write_fd_int::native-32, _rest::binary>>,
            level: :socket,
            type: :rights
          }
        ]
      } = msg

      :socket.close(sock)

      with {:ok, write_fd} <- Nif.nif_create_fd(write_fd_int),
           {:ok, read_fd} <- Nif.nif_create_fd(read_fd_int) do
        {write_fd, read_fd}
      else
        error ->
          raise Error,
            message: "Failed to create fd resources\n  error: #{inspect(error)}"
      end
    else
      error ->
        raise Error,
          message:
            "Failed to receive stdin and stdout file descriptors\n  error: #{inspect(error)}"
    end
  end
end
