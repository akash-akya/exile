defmodule Exile.ProcessNif do
  @moduledoc false
  @on_load :load_nifs

  def load_nifs do
    nif_path = :filename.join(:code.priv_dir(:exile), "exile")
    :erlang.load_nif(nif_path, 0)
  end

  def execute(_cmd, _dir, _env, _stderr_to_console),
    do: :erlang.nif_error(:nif_library_not_loaded)

  def sys_write(_context, _bin), do: :erlang.nif_error(:nif_library_not_loaded)

  def sys_read(_context, _bytes), do: :erlang.nif_error(:nif_library_not_loaded)

  def sys_close(_context, _pipe), do: :erlang.nif_error(:nif_library_not_loaded)

  def sys_kill(_context), do: :erlang.nif_error(:nif_library_not_loaded)

  def sys_terminate(_context), do: :erlang.nif_error(:nif_library_not_loaded)

  def sys_wait(_context), do: :erlang.nif_error(:nif_library_not_loaded)

  def os_pid(_context), do: :erlang.nif_error(:nif_library_not_loaded)

  def alive?(_context), do: :erlang.nif_error(:nif_library_not_loaded)

  # non-nif helper functions
  defmacro fork_exec_failure(), do: 125

  defmacro nif_false(), do: 0
  defmacro nif_true(), do: 1

  def to_process_fd(:stdin), do: 0
  def to_process_fd(:stdout), do: 1
end
