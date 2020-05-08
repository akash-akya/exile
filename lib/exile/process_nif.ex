defmodule Exile.ProcessNif do
  @on_load :load_nifs

  def load_nifs do
    nif_path = :filename.join(:code.priv_dir(:exile), "exile")
    :erlang.load_nif(nif_path, 0)
  end

  def exec_proc(_cmd, _stderr_to_console), do: :erlang.nif_error(:nif_library_not_loaded)

  def write_proc(_context, _bin), do: :erlang.nif_error(:nif_library_not_loaded)

  def read_proc(_context, _bytes), do: :erlang.nif_error(:nif_library_not_loaded)

  def close_pipe(_context, _pipe), do: :erlang.nif_error(:nif_library_not_loaded)

  def kill_proc(_context), do: :erlang.nif_error(:nif_library_not_loaded)

  def terminate_proc(_context), do: :erlang.nif_error(:nif_library_not_loaded)

  def wait_proc(_context), do: :erlang.nif_error(:nif_library_not_loaded)

  def os_pid(_context), do: :erlang.nif_error(:nif_library_not_loaded)

  def is_alive(_context), do: :erlang.nif_error(:nif_library_not_loaded)
end
