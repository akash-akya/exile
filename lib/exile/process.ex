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

  # delay between exit_check when io is busy (in milliseconds)
  @exit_check_timeout 5

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
    %{cmd_with_args: cmd_with_args, cd: cd, env: env} = state.args
    socket_path = socket_path()

    {:ok, uds} = :socket.open(:local, :stream, :default)
    _ = :file.delete(socket_path)
    {:ok, _} = :socket.bind(uds, %{family: :local, path: socket_path})
    :ok = :socket.listen(uds)

    port = exec(cmd_with_args, socket_path, env, cd)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Exile.Watcher.watch(self(), os_pid, socket_path)

    {write_fd_int, read_fd_int} = receive_fds(uds)

    {:ok, write_fd} = Nif.nif_create_fd(write_fd_int)
    {:ok, read_fd} = Nif.nif_create_fd(read_fd_int)

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
    # watcher will take care of termination of external process

    # TODO: pending write and read should receive "stopped" return
    # value instead of exit signal
    Port.close(state.port)

    {:stop, :normal, :ok, state}
  end

  def handle_call(_, _from, %{status: {:exit, status}}), do: {:reply, {:error, {:exit, status}}}

  def handle_call({:await_exit, timeout}, from, state) do
    tref =
      if timeout != :infinity do
        Elixir.Process.send_after(self(), {:await_exit_timeout, from}, timeout)
      else
        nil
      end

    state = put_timer(state, from, :timeout, tref)
    check_exit(state, from)
  end

  def handle_call({:write, binary}, from, state) when is_binary(binary) do
    pending = %Pending{bin: binary, client_pid: from}
    do_write(%Process{state | pending_write: pending})
  end

  def handle_call({:read, size}, from, state) do
    pending = %Pending{remaining: size, client_pid: from}
    do_read(%Process{state | pending_read: pending})
  end

  def handle_call(:close_stdin, _from, state), do: do_close(state, :stdin)

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

  def handle_info({:check_exit, from}, state), do: check_exit(state, from)

  def handle_info({:await_exit_timeout, from}, state) do
    cancel_timer(state, from, :check)

    receive do
      {:check_exit, ^from} -> :ok
    after
      0 -> :ok
    end

    GenServer.reply(from, :timeout)
    {:noreply, clear_await(state, from)}
  end

  def handle_info({:select, _write_resource, _ref, :ready_output}, state), do: do_write(state)

  def handle_info({:select, _read_resource, _ref, :ready_input}, state), do: do_read(state)

  def handle_info({port, {:exit_status, exit_status}}, %{port: port} = state),
    do: handle_port_exit(exit_status, state)

  def handle_info(msg, _state), do: raise(msg)

  defp handle_port_exit(exit_status, state) do
    {:noreply, %{state | status: {:exit, exit_status}}}
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
        {:noreply, state}

      {:ok, binary} ->
        GenServer.reply(pending.client_pid, {:ok, binary})
        {:noreply, state}

      {:error, :eagain} ->
        {:noreply, state}

      {:error, errno} ->
        GenServer.reply(pending.client_pid, {:error, errno})
        {:noreply, %{state | errno: errno}}
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

  defp check_exit(state, from) do
    case state.status do
      # {:ok, {:exit, Nif.fork_exec_failure()}} ->
      #   GenServer.reply(from, {:error, :failed_to_execute})
      #   cancel_timer(state, from, :timeout)
      #   {:noreply, clear_await(state, from)}

      {:exit, status} ->
        GenServer.reply(from, {:ok, {:exit, status}})
        cancel_timer(state, from, :timeout)
        {:noreply, clear_await(state, from)}

      :start ->
        tref = Elixir.Process.send_after(self(), {:check_exit, from}, @exit_check_timeout)
        {:noreply, put_timer(state, from, :check, tref)}
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
        raise errno
        {:reply, {:error, errno}, %Process{state | errno: errno}}
    end
  end

  defp clear_await(state, from) do
    %Process{state | await: Map.delete(state.await, from)}
  end

  defp cancel_timer(state, from, key) do
    case get_timer(state, from, key) do
      nil -> :ok
      tref -> Elixir.Process.cancel_timer(tref)
    end
  end

  defp put_timer(state, from, key, timer) do
    if Map.has_key?(state.await, from) do
      await = put_in(state.await, [from, key], timer)
      %Process{state | await: await}
    else
      %Process{state | await: %{from => %{key => timer}}}
    end
  end

  defp get_timer(state, from, key), do: get_in(state.await, [from, key])

  defp normalize_cmd(cmd) do
    path = System.find_executable(cmd)

    if path do
      {:ok, to_charlist(path)}
    else
      {:error, "command not found: #{inspect(cmd)}"}
    end
  end

  defp normalize_cmd_args(args) do
    if is_list(args) do
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
    user_env =
      Map.new(env, fn {key, value} ->
        {String.trim(key), String.trim(value)}
      end)

    # spawned process env will be beam env at that time + user env.
    # this is similar to erlang behavior
    env_list =
      Map.merge(System.get_env(), user_env)
      |> Enum.map(fn {k, v} ->
        to_charlist(k <> "=" <> v)
      end)

    {:ok, env_list}
  end

  defp validate_opts_fields(opts) do
    {_, additional_opts} = Keyword.split(opts, [:cd, :env])

    if Enum.empty?(additional_opts) do
      :ok
    else
      {:error, "invalid opts: #{inspect(additional_opts)}"}
    end
  end

  defp normalize_args([cmd | args], opts) when is_list(opts) do
    with {:ok, cmd} <- normalize_cmd(cmd),
         {:ok, args} <- normalize_cmd_args(args),
         :ok <- validate_opts_fields(opts),
         {:ok, cd} <- normalize_cd(opts[:cd]),
         {:ok, env} <- normalize_env(opts[:env]) do
      {:ok, %{cmd_with_args: [cmd | args], cd: cd, env: env}}
    end
  end

  defp normalize_args(_, _), do: {:error, "invalid arguments"}

  @spawner_path Path.expand("../../c_src/spawner", __DIR__) |> to_charlist()

  defp exec(cmd_with_args, socket_path, env, cd) do
    opts = []

    # opts = if cd, do: [cd: cd], else: []
    # opts = if env, do: [{:env, env} | opts], else: opts

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
    dir = System.tmp_dir!()
    Path.join(dir, randome_string())
  end

  defp randome_string do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64() |> binary_part(0, 16)
  end

  defp signal(port, sig) when sig in [:sigkill, :sigterm] do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        Nif.nif_kill(os_pid, sig)

      :undefined ->
        {:error, :process_not_alive}
    end
  end

  @timeout 2000
  defp receive_fds(uds) do
    case :socket.accept(uds, @timeout) do
      {:ok, usock} ->
        {:ok, msg} = :socket.recvmsg(usock)

        %{
          ctrl: [
            %{
              data: <<read_fd_int::native-32, write_fd_int::native-32, _rest::binary>>,
              level: :socket,
              type: :rights
            }
          ]
        } = msg

        :socket.close(usock)
        {write_fd_int, read_fd_int}

      error ->
        raise error
    end
  end
end
