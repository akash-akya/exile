defmodule Exile do
  @on_load :load_nifs

  def load_nifs do
    :erlang.load_nif('./priv/hello', 0)
  end

  def fast_compare(_a, _b) do
    raise "NIF fast_compare/2 not implemented"
  end

  def exec_proc(_cmd) do
    raise "NIF exec_proc/0 not implemented"
  end

  def write_proc(_cmd) do
    raise "NIF exec_proc/0 not implemented"
  end

  def read_proc(_cmd) do
    raise "NIF exec_proc/0 not implemented"
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

  def pid_info(_pid) do
    raise "NIF pid_info/1 not implemented"
  end

  def ps(pid) do
    {out, 0} = System.cmd("ps", [to_string(pid)])
    out
  end
end
