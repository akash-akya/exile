defmodule Exile.Process.Pipe do
  @moduledoc false

  alias Exile.Process.Nif
  require Logger

  @type name :: Exile.Process.pipe_name()

  @type fd :: non_neg_integer()

  @type t :: %__MODULE__{
          name: name,
          fd: pos_integer() | nil,
          monitor_ref: reference() | nil,
          owner: pid | nil,
          status: :open | :closed
        }

  defstruct [:name, :fd, :monitor_ref, :owner, status: :init]

  alias __MODULE__

  @spec new(name, pos_integer, pid) :: t
  def new(name, fd, owner) do
    if name in [:stdin, :stdout, :stderr] do
      ref = Process.monitor(owner)
      %Pipe{name: name, fd: fd, status: :open, owner: owner, monitor_ref: ref}
    else
      raise "invalid pipe name"
    end
  end

  @spec new(name) :: t
  def new(name) do
    if name in [:stdin, :stdout, :stderr] do
      %Pipe{name: name, status: :closed}
    else
      raise "invalid pipe name"
    end
  end

  @spec open?(t) :: boolean()
  def open?(pipe), do: pipe.status == :open

  @spec read(t, non_neg_integer, pid) :: :eof | {:ok, binary} | {:error, :eagain} | {:error, term}
  def read(pipe, size, caller) do
    if caller != pipe.owner do
      {:error, :pipe_closed_or_invalid_caller}
    else
      case Nif.nif_read(pipe.fd, size) do
        # normalize return value
        {:ok, <<>>} -> :eof
        {:error, :invalid_fd_resource} -> {:error, :pipe_closed_or_invalid_caller}
        ret -> ret
      end
    end
  end

  @spec write(t, binary, pid) :: {:ok, size :: non_neg_integer()} | {:error, term}
  def write(pipe, bin, caller) do
    if caller != pipe.owner do
      {:error, :pipe_closed_or_invalid_caller}
    else
      case Nif.nif_write(pipe.fd, bin) do
        {:error, :invalid_fd_resource} -> {:error, :pipe_closed_or_invalid_caller}
        ret -> ret
      end
    end
  end

  @spec close(t, pid) :: {:ok, t} | {:error, :pipe_closed_or_invalid_caller}
  def close(%Pipe{} = pipe, caller) do
    if caller != pipe.owner do
      {:error, :pipe_closed_or_invalid_caller}
    else
      Process.demonitor(pipe.monitor_ref, [:flush])
      result = Nif.nif_close(pipe.fd)
      if result != :ok, do: Logger.debug("Exile: nif_close returned #{inspect(result)}")
      pipe = %Pipe{pipe | status: :closed, monitor_ref: nil, owner: nil}

      {:ok, pipe}
    end
  end

  @spec set_owner(t, pid) :: {:ok, t} | {:error, :closed}
  def set_owner(%Pipe{} = pipe, new_owner) do
    if pipe.status == :open do
      ref = Process.monitor(new_owner)
      Process.demonitor(pipe.monitor_ref, [:flush])
      pipe = %Pipe{pipe | owner: new_owner, monitor_ref: ref}

      {:ok, pipe}
    else
      {:error, :closed}
    end
  end
end
