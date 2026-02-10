defmodule Exile.Process.Nif do
  @moduledoc false
  @on_load :load_nifs

  # Internal wrapper around native functions. Access is further constrained in
  # the NIF layer by per-resource controller pid checks.
  def load_nifs do
    nif_path = :filename.join(:code.priv_dir(:exile), "exile")
    :erlang.load_nif(nif_path, 0)
  end

  def nif_is_os_pid_alive(_os_pid), do: :erlang.nif_error(:nif_library_not_loaded)

  def nif_kill(_os_pid, _signal), do: :erlang.nif_error(:nif_library_not_loaded)

  def nif_read(_fd, _max_size), do: :erlang.nif_error(:nif_library_not_loaded)

  def nif_create_fd(_fd), do: :erlang.nif_error(:nif_library_not_loaded)

  def nif_close(_fd), do: :erlang.nif_error(:nif_library_not_loaded)

  def nif_write(_fd, _bin), do: :erlang.nif_error(:nif_library_not_loaded)
end
