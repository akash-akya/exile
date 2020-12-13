defmodule UDS do
  alias Exile.ProcessNif, as: Nif

  def main(path, args) do
    {:ok, uds} = :socket.open(:local, :stream, :default)
    _ = :file.delete(path)
    {:ok, _} = :socket.bind(uds, %{family: :local, path: path})
    :ok = :socket.listen(uds)

    IO.puts("Listening UNIX socket #{path} for worker connection")

    _port = exec(path, args)

    case :socket.accept(uds, 2000) do
      {:ok, usock} ->
        echo_acc_loop(usock, path)
        :socket.close(usock)

      error ->
        raise error
    end
  end

  defp exec(path, args) do
    spawner_path = Path.expand("../c_src/spawner", __DIR__)

    Port.open({:spawn_executable, to_charlist(spawner_path)}, [
      :nouse_stdio,
      :exit_status,
      :binary,
      args: [path | args]
    ])
    |> IO.inspect(label: :os_proc)
  end

  def echo_acc_loop(uds, _path) do
    case :socket.recvmsg(uds) do
      {:ok, msg} ->
        handle_msg(msg)

      # echo_acc_loop(uds, path)

      err ->
        IO.puts("Failed to recvmsg: #{inspect(err)}")
        :socket.close(uds)
    end
  end

  def handle_msg(%{
        ctrl: [
          %{
            data: <<read_fd::native-32, write_fd::native-32, _rest::binary>>,
            level: :socket,
            type: :rights
          }
        ]
      }) do
    IO.inspect(read_fd, label: :read_fd)
    IO.inspect(write_fd, label: :write_fd)
    # read(write_fd)
    {:ok, fd} = Nif.nif_create_fd(write_fd)
    nif_read(fd)
  end

  defp nif_read(fd) do
    case Nif.nif_read_async(fd, 65535) do
      {:ok, <<>>} ->
        Nif.nif_close(fd)
        IO.puts("\nEOF")

      {:ok, bin} ->
        IO.puts("READ: #{IO.iodata_length(bin)}")
        nif_read(fd)

      {:error, :eagain} ->
        IO.puts(":eagain")
        wait_for_ready(fd)

      {:error, error} ->
        IO.inspect(error)
    end
  end

  defp wait_for_ready(fd) do
    receive do
      {:select, _read_resource, _ref, :ready_input} ->
        nif_read(fd)
    end
  end

  # defp read(fd) do
  #   port = Port.open({:fd, fd, fd}, [:in, :binary, :eof])
  #   do_read(port)
  # end

  # defp do_read(port) do
  #   receive do
  #     {^port, {:data, data}} ->
  #       IO.puts(IO.iodata_length(data))
  #       do_read(port)

  #     {^port, msg} ->
  #       IO.inspect(msg)

  #     msg ->
  #       IO.inspect(msg)
  #       do_read(port)
  #   end
  # end
end
