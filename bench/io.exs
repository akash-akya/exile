defmodule ExileBench.Read do
  @size 1000
  @chunk_size 1024 * 4
  @data :crypto.strong_rand_bytes(@chunk_size)

  defp exile_read_loop(s, @size), do: Exile.Process.close_stdin(s)

  defp exile_read_loop(s, count) do
    :ok = Exile.Process.write(s, @data)

    case Exile.Process.read(s, @chunk_size) do
      {:ok, _data} -> exile_read_loop(s, count + 1)
      {:eof, _} -> :ok
    end
  end

  def exile do
    {:ok, s} = Exile.Process.start_link(["cat"])
    :ok = exile_read_loop(s, 0)
    Exile.Process.stop(s)
  end

  # port
  defp port_read(_port, 0), do: :ok
  defp port_read(port, size) do
    receive do
      {^port, {:data, data}} -> port_read(port, size - IO.iodata_length(data))
    end
  end

  defp port_loop(_port, @size), do: :ok

  defp port_loop(port, count) do
    true = Port.command(port, @data)
    :ok = port_read(port, @chunk_size)
    port_loop(port, count + 1)
  end

  def port do
    cat = :os.find_executable('cat')

    port =
      Port.open({:spawn_executable, cat}, [
        :use_stdio,
        :exit_status,
        :binary
      ])

    port_loop(port, 0)
    Port.close(port)
  end


  # ex_cmd
  defp ex_cmd_read_loop(s, @size), do: ExCmd.Process.close_stdin(s)

  defp ex_cmd_read_loop(s, count) do
    :ok = ExCmd.Process.write(s, @data)

    case ExCmd.Process.read(s, @chunk_size) do
      {:ok, _data} -> ex_cmd_read_loop(s, count + 1)
      :eof -> :ok
    end
  end

  def ex_cmd do
    {:ok, s} = ExCmd.Process.start_link(["cat"])
    :ok = ex_cmd_read_loop(s, 0)
    ExCmd.Process.stop(s)
  end
end

read_jobs = %{
  "Exile" => fn -> ExileBench.Read.exile() end,
  "Port"  => fn ->  ExileBench.Read.port() end,
  "ExCmd"  => fn ->  ExileBench.Read.ex_cmd() end
}

Benchee.run(read_jobs,
  #  parallel: 4,
  warmup: 5,
  time: 30,
  memory_time: 1,
  formatters: [
    {Benchee.Formatters.HTML, file: Path.expand("output/read.html", __DIR__)},
    Benchee.Formatters.Console
  ]
)
