defmodule Exile.Process.Exec do
  @moduledoc false

  alias Exile.Process.Nif
  alias Exile.Process.Pipe
  alias Exile.Process.State

  @type args :: %{
          cmd_with_args: [String.t()],
          cd: String.t(),
          env: [{String.t(), String.t()}]
        }

  @spec start(args, State.stderr_mode()) :: %{
          port: port,
          stdin: non_neg_integer(),
          stdout: non_neg_integer(),
          stderr: non_neg_integer()
        }
  def start(args, stderr) do
    %{cmd_with_args: cmd_with_args, cd: cd, env: env} = args
    socket_path = socket_path()
    {:ok, sock} = :socket.open(:local, :stream, :default)

    try do
      :ok = socket_bind(sock, socket_path)
      :ok = :socket.listen(sock)

      spawner_cmdline_args = [socket_path, to_string(stderr) | cmd_with_args]

      port_opts =
        [:nouse_stdio, :exit_status, :binary, args: spawner_cmdline_args] ++
          prune_nils(env: env, cd: cd)

      port = Port.open({:spawn_executable, spawner_path()}, port_opts)

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      Exile.Watcher.watch(self(), os_pid, socket_path)

      {stdin_fd, stdout_fd, stderr_fd} = receive_fds(sock, stderr)

      %{port: port, stdin: stdin_fd, stdout: stdout_fd, stderr: stderr_fd}
    after
      :socket.close(sock)
      File.rm!(socket_path)
    end
  end

  @spec normalize_exec_args(nonempty_list(), keyword()) ::
          {:ok,
           %{
             cmd_with_args: nonempty_list(),
             cd: charlist,
             env: env,
             stderr: :console | :disable | :consume
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

  @spec receive_fds(:socket.socket(), State.stderr_mode()) :: {Pipe.fd(), Pipe.fd(), Pipe.fd()}
  defp receive_fds(lsock, stderr_mode) do
    {:ok, sock} = :socket.accept(lsock, @socket_timeout)

    try do
      {:ok, msg} = :socket.recvmsg(sock, @socket_timeout)
      %{ctrl: [%{data: data, level: :socket, type: :rights}]} = msg

      <<stdin_fd::native-32, stdout_fd::native-32, stderr_fd::native-32, _::binary>> = data

      # FDs are managed by the NIF resource life-cycle
      {:ok, stdout} = Nif.nif_create_fd(stdout_fd)
      {:ok, stdin} = Nif.nif_create_fd(stdin_fd)
      {:ok, stderr} = Nif.nif_create_fd(stderr_fd)

      stderr =
        if stderr_mode == :consume do
          stderr
        else
          # we have to explicitly close FD passed over socket.
          # Since it will be tracked by the OS and kept open until we close.
          Nif.nif_close(stderr)
          nil
        end

      {stdin, stdout, stderr}
    after
      :socket.close(sock)
    end
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
    path = Path.join(System.tmp_dir!(), str)
    _ = :file.delete(path)
    path
  end

  @spec prune_nils(keyword()) :: keyword()
  defp prune_nils(kv) do
    Enum.reject(kv, fn {_, v} -> is_nil(v) end)
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

  @spec normalize_stderr(stderr :: :console | :disable | :consume | nil) ::
          {:ok, :console | :disable | :consume} | {:error, String.t()}
  defp normalize_stderr(stderr) do
    case stderr do
      nil ->
        {:ok, :console}

      stderr when stderr in [:console, :disable, :consume] ->
        {:ok, stderr}

      _ ->
        {:error, ":stderr must be an atom and one of :console, :disable, :consume"}
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
