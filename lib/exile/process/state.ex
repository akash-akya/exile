defmodule Exile.Process.State do
  @moduledoc false

  alias Exile.Process.Exec
  alias Exile.Process.Operations
  alias Exile.Process.Pipe

  alias __MODULE__

  @type read_mode :: :stdout | :stderr | :stdout_or_stderr

  @type stderr_mode :: :console | :redirect_to_stdout | :disable | :consume

  @type pipes :: %{
          stdin: Pipe.t(),
          stdout: Pipe.t(),
          stderr: Pipe.t()
        }

  @type status ::
          :init
          | :running
          | {:exit, non_neg_integer()}
          | {:exit, {:error, error :: term}}

  @type t :: %__MODULE__{
          args: Exec.args(),
          owner: pid,
          port: port(),
          pipes: pipes,
          status: status,
          stderr: stderr_mode,
          operations: Operations.t(),
          exit_ref: reference(),
          monitor_ref: reference()
        }

  defstruct [
    :args,
    :owner,
    :port,
    :pipes,
    :status,
    :stderr,
    :operations,
    :exit_ref,
    :monitor_ref
  ]

  alias __MODULE__

  @spec pipe(State.t(), name :: Pipe.name()) :: {:ok, Pipe.t()} | {:error, :invalid_name}
  def pipe(%State{} = state, name) do
    if name in [:stdin, :stdout, :stderr] do
      {:ok, Map.fetch!(state.pipes, name)}
    else
      {:error, :invalid_name}
    end
  end

  @spec put_pipe(State.t(), name :: Pipe.name(), Pipe.t()) :: {:ok, t} | {:error, :invalid_name}
  def put_pipe(%State{} = state, name, pipe) do
    if name in [:stdin, :stdout, :stderr] do
      pipes = Map.put(state.pipes, name, pipe)
      state = %State{state | pipes: pipes}
      {:ok, state}
    else
      {:error, :invalid_name}
    end
  end

  @spec pipe_name_for_fd(State.t(), fd :: Pipe.fd()) :: Pipe.name()
  def pipe_name_for_fd(state, fd) do
    pipe =
      state.pipes
      |> Map.values()
      |> Enum.find(&(&1.fd == fd))

    pipe.name
  end

  @spec put_operation(State.t(), Operations.operation()) :: {:ok, t} | {:error, term}
  def put_operation(%State{operations: ops} = state, operation) do
    with {:ok, ops} <- Operations.put(ops, operation) do
      {:ok, %State{state | operations: ops}}
    end
  end

  @spec pop_operation(State.t(), Operations.name()) ::
          {:ok, Operations.operation(), t} | {:error, term}
  def pop_operation(%State{operations: ops} = state, name) do
    with {:ok, operation, ops} <- Operations.pop(ops, name) do
      {:ok, operation, %State{state | operations: ops}}
    end
  end

  @spec set_status(State.t(), status) :: State.t()
  def set_status(%State{} = state, status) do
    %State{state | status: status}
  end
end
