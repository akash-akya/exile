defmodule Exile.ProcessHelper do
  @on_load :load_nifs

  def load_nifs do
    :erlang.load_nif('./priv/exile_nif', 0)
  end

  def exec_proc(_cmd, _stderr_to_console) do
    raise "NIF exec_proc/0 not implemented"
  end

  def write_proc(_pipe, _bin) do
    raise "NIF write_proc/2 not implemented"
  end

  def read_proc(_pipe, _bytes) do
    raise "NIF read_proc/0 not implemented"
  end

  def close_pipe(_pipe) do
    raise "NIF close_pipe/1 not implemented"
  end

  def kill_proc(_pid) do
    raise "NIF kill_proc/1 not implemented"
  end

  def terminate_proc(_pid) do
    raise "NIF terminate_proc/1 not implemented"
  end

  def wait_proc(_pid) do
    raise "NIF wait_proc/1 not implemented"
  end

  def is_alive(_pid) do
    raise "NIF is_alive/1 not implemented"
  end
end
