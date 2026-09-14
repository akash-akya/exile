defmodule Exile.Process.Exec do
  @moduledoc false

  alias Exile.Process.Error
  alias Exile.Process.Nif
  alias Exile.Process.Pipe
  alias Exile.Process.State

  @type args :: %{
          cmd_with_args: [String.t()],
          cd: String.t(),
          env: [{String.t(), String.t()}]
        }

  @type handles :: %{
          port: port(),
          stdin: Pipe.fd(),
          stdout: Pipe.fd(),
          stderr: Pipe.fd() | nil
        }

  @spec start(args, State.stderr_mode()) :: handles()
  @spec start(args, State.stderr_mode(), String.t()) :: handles()
  def start(args, stderr, spawner \\ spawner_path()) do
    %{cmd_with_args: cmd_with_args, cd: cd, env: env} = args
    socket_path = socket_path()
    listener = bind_socket(socket_path, spawner)

    try do
      startup_result!(:socket.listen(listener), :listen, spawner)
      spawner_args = [socket_path, to_string(stderr) | cmd_with_args]

      port_opts =
        [:nouse_stdio, :exit_status, :binary, args: spawner_args] ++
          prune_nils(env: env, cd: cd)

      port = open_port(spawner, port_opts)

      try do
        # Watch before the handshake so owner death also cleans up a stalled helper.
        maybe_watch_process(port, socket_path)
        {stdin, stdout, stderr} = receive_fds(listener, port, stderr, spawner)
        %{port: port, stdin: stdin, stdout: stdout, stderr: stderr}
      rescue
        error ->
          stop_port(port)
          reraise error, __STACKTRACE__
      end
    after
      :socket.close(listener)
      File.rm(socket_path)
    end
  end

  defp bind_socket(path, spawner) do
    socket = startup_result!(:socket.open(:local, :stream, :default), :open, spawner)

    case socket_bind(socket, path) do
      :ok ->
        socket

      {:error, reason} ->
        :socket.close(socket)
        startup_error!(:bind, reason, spawner)
    end
  end

  defp open_port(spawner, opts) do
    Port.open({:spawn_executable, spawner}, opts)
  rescue
    error in ErlangError -> startup_error!(:port_open, error.original, spawner)
    ArgumentError -> startup_error!(:port_open, :badarg, spawner)
    SystemLimitError -> startup_error!(:port_open, :system_limit, spawner)
  end

  defp stop_port(port) do
    case os_pid(port) do
      {:ok, os_pid} -> Nif.nif_kill(os_pid, :sigkill)
      :undefined -> :ok
    end

    # Port.close alone does not terminate an OS process, and the port may
    # disappear between fetching its pid and closing it.
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  @spec normalize_exec_args(nonempty_list(), keyword()) ::
          {:ok,
           %{
             cmd_with_args: nonempty_list(),
             cd: charlist,
             env: env,
             stderr: :console | :redirect_to_stdout | :disable | :consume
           }}
          | {:error, String.t()}
  def normalize_exec_args(cmd_with_args, opts) do
    with {:ok, cmd} <- normalize_cmd(cmd_with_args),
         {:ok, args} <- normalize_cmd_args(cmd_with_args),
         :ok <- validate_opts_fields(opts),
         {:ok, cd} <- normalize_cd(opts[:cd]),
         {:ok, stderr} <- normalize_stderr(opts[:stderr]),
         {:ok, env} <- normalize_env(opts[:env]) do
      {:ok, %{cmd_with_args: [cmd | args], cd: cd, env: env, stderr: stderr}}
    end
  end

  @spec spawner_path :: String.t()
  defp spawner_path do
    :filename.join(:code.priv_dir(:exile), "spawner")
  end

  @socket_timeout 2000

  @spec receive_fds(:socket.socket(), port(), State.stderr_mode(), String.t()) ::
          {Pipe.fd(), Pipe.fd(), Pipe.fd() | nil}
  defp receive_fds(listener, port, stderr_mode, spawner) do
    socket =
      :socket.accept(listener, @socket_timeout)
      |> startup_result!(:accept, spawner, port)

    try do
      msg =
        :socket.recvmsg(socket, @socket_timeout)
        |> startup_result!(:recvmsg, spawner, port)

      adopt_fds(msg, stderr_mode, spawner)
    after
      :socket.close(socket)
    end
  end

  defp adopt_fds(msg, stderr_mode, spawner) do
    # Adopt every received descriptor, including extras, so invalid messages
    # cannot leave raw FDs outside the NIF's ownership.
    results =
      for %{level: :socket, type: :rights, data: data} <- msg.ctrl,
          <<fd::native-32 <- data>> do
        Nif.nif_create_fd(fd)
      end

    try do
      if :error in results do
        startup_error!(:create_fd, :error, spawner)
      end

      if :ctrunc in msg.flags do
        startup_error!(:recvmsg, :truncated_fd_message, spawner)
      end

      case results do
        [{:ok, stdin}, {:ok, stdout}, {:ok, stderr}] ->
          if stderr_mode == :consume do
            {stdin, stdout, stderr}
          else
            Nif.nif_close(stderr)
            {stdin, stdout, nil}
          end

        _ ->
          startup_error!(:recvmsg, :invalid_fd_message, spawner)
      end
    rescue
      error ->
        for {:ok, resource} <- results, do: Nif.nif_close(resource)
        reraise error, __STACKTRACE__
    end
  end

  defp startup_result!(result, operation, spawner, port \\ nil) do
    case result do
      :ok -> :ok
      {:ok, value} -> value
      {:error, reason} -> startup_error!(operation, reason, spawner, port)
    end
  end

  defp startup_error!(operation, reason, spawner, port \\ nil) do
    # Only inspect port exits after failure: successful fast commands must leave
    # their exit notification available for the GenServer's normal handling.
    {reason, exit_status, detail} =
      receive do
        {^port, {:exit_status, status}} ->
          {:spawner_exit, status, "spawner exited with status #{status}"}
      after
        0 -> {reason, nil, inspect(reason)}
      end

    raise Error,
      message: "startup failed during #{operation}: #{detail} (helper: #{spawner})",
      operation: operation,
      reason: reason,
      helper_path: spawner,
      exit_status: exit_status
  end

  # skip type warning till we change min OTP version to 24.
  @dialyzer {:nowarn_function, socket_bind: 2}
  defp socket_bind(sock, path) do
    case :socket.bind(sock, %{family: :local, path: path}) do
      :ok -> :ok
      # for compatibility with OTP version < 24
      {:ok, _} -> :ok
      other -> other
    end
  end

  @spec socket_path() :: String.t()
  defp socket_path do
    str = :crypto.strong_rand_bytes(16) |> Base.url_encode64() |> binary_part(0, 16)
    Path.join(System.tmp_dir!(), str)
  end

  @spec prune_nils(keyword()) :: keyword()
  defp prune_nils(kv) do
    Enum.reject(kv, fn {_, v} -> is_nil(v) end)
  end

  @doc false
  @spec os_pid(port()) :: {:ok, pos_integer()} | :undefined
  def os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        {:ok, os_pid}

      nil ->
        :undefined
    end
  end

  @spec maybe_watch_process(port(), String.t()) :: :ok
  defp maybe_watch_process(port, socket_path) do
    case os_pid(port) do
      {:ok, os_pid} ->
        _ = Exile.Watcher.watch(self(), os_pid, socket_path)
        :ok

      :undefined ->
        :ok
    end
  end

  @spec normalize_cmd(nonempty_list()) :: {:ok, nonempty_list()} | {:error, binary()}
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
    if Enum.all?(args, &is_binary/1) do
      {:ok, Enum.map(args, &to_charlist/1)}
    else
      {:error, "command arguments must be list of strings. #{inspect(args)}"}
    end
  end

  @spec normalize_cd(binary) :: {:ok, charlist()} | {:error, String.t()}
  defp normalize_cd(cd) do
    case cd do
      nil ->
        {:ok, ~c""}

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

  @type env :: list({String.t(), String.t()})

  @spec normalize_env(env) :: {:ok, env} | {:error, String.t()}
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

  @spec normalize_stderr(stderr :: :console | :redirect_to_stdout | :disable | :consume | nil) ::
          {:ok, :console | :redirect_to_stdout | :disable | :consume} | {:error, String.t()}
  defp normalize_stderr(stderr) do
    case stderr do
      nil ->
        {:ok, :console}

      stderr when stderr in [:redirect_to_stdout, :console, :disable, :consume] ->
        {:ok, stderr}

      _ ->
        {:error,
         ":stderr must be an atom and one of :redirect_to_stdout, :console, :disable, :consume"}
    end
  end

  @spec validate_opts_fields(keyword) :: :ok | {:error, String.t()}
  defp validate_opts_fields(opts) do
    {_, additional_opts} = Keyword.split(opts, [:cd, :env, :stderr])

    if Enum.empty?(additional_opts) do
      :ok
    else
      {:error, "invalid opts: #{inspect(additional_opts)}"}
    end
  end
end
