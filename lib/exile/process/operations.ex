defmodule Exile.Process.Operations do
  @moduledoc false

  alias Exile.Process.Pipe
  alias Exile.Process.State

  @type t :: %__MODULE__{
          write_stdin: write_operation() | nil,
          read_stdout: read_operation() | nil,
          read_stderr: read_operation() | nil,
          read_stdout_or_stderr: read_any_operation() | nil
        }

  defstruct [:write_stdin, :read_stdout, :read_stderr, :read_stdout_or_stderr]

  @spec new :: t
  def new, do: %__MODULE__{}

  @type write_operation ::
          {:write_stdin, GenServer.from(), binary}

  @type read_operation ::
          {:read_stdout, GenServer.from(), non_neg_integer()}
          | {:read_stderr, GenServer.from(), non_neg_integer()}

  @type read_any_operation ::
          {:read_stdout_or_stderr, GenServer.from(), non_neg_integer()}

  @type operation :: write_operation() | read_operation() | read_any_operation()

  @type name :: :write_stdin | :read_stdout | :read_stderr | :read_stdout_or_stderr

  @spec get(t, name) :: {:ok, operation()} | {:error, term}
  def get(operations, name) do
    {:ok, Map.fetch!(operations, name)}
  end

  @spec pop(t, name) :: {:ok, operation, t} | {:error, term}
  def pop(operations, name) do
    case Map.get(operations, name) do
      nil ->
        {:error, :operation_not_found}

      operation ->
        {:ok, operation, Map.put(operations, name, nil)}
    end
  end

  @spec put(t, operation()) :: {:ok, t} | {:error, term}
  def put(operations, operation) do
    with {:ok, {op_name, _from, _arg} = operation} <- validate_operation(operation) do
      {:ok, Map.put(operations, op_name, operation)}
    end
  end

  @spec read_any(State.t(), read_any_operation()) ::
          :eof
          | {:noreply, State.t()}
          | {:ok, {:stdout | :stderr, binary}}
          | {:error, term}
  def read_any(state, {:read_stdout_or_stderr, _from, _size} = operation) do
    with {:ok, {_name, {caller, _}, arg}} <- validate_read_any_operation(operation),
         first <- pipe_name(operation),
         {:ok, primary} <- State.pipe(state, first),
         second <- if(first == :stdout, do: :stderr, else: :stdout),
         {:ok, secondary} <- State.pipe(state, second),
         {:error, :eagain} <- do_read_any(caller, arg, primary, secondary),
         {:ok, new_state} <- State.put_operation(state, operation) do
      # dbg(new_state)
      {:noreply, new_state}
    end
  end

  @spec read(State.t(), read_operation()) ::
          :eof
          | {:noreply, State.t()}
          | {:ok, binary}
          | {:error, term}
  def read(state, operation) do
    with {:ok, {_name, {caller, _}, arg}} <- validate_read_operation(operation),
         {:ok, pipe} <- State.pipe(state, pipe_name(operation)),
         {:error, :eagain} <- Pipe.read(pipe, arg, caller),
         {:ok, new_state} <- State.put_operation(state, operation) do
      {:noreply, new_state}
    end
  end

  @spec write(State.t(), write_operation()) ::
          :ok
          | {:noreply, State.t()}
          | {:error, :epipe}
          | {:error, term}
  def write(state, operation) do
    with {:ok, {_name, {caller, _}, bin}} <- validate_write_operation(operation),
         pipe_name <- pipe_name(operation),
         {:ok, pipe} <- State.pipe(state, pipe_name) do
      case Pipe.write(pipe, bin, caller) do
        {:ok, size} ->
          handle_successful_write(state, size, operation)

        {:error, :eagain} ->
          case State.put_operation(state, operation) do
            {:ok, new_state} ->
              {:noreply, new_state}

            error ->
              error
          end

        ret ->
          ret
      end
    end
  end

  @spec match_pending_operation(State.t(), Pipe.name()) ::
          {:ok, name} | {:error, :no_pending_operation}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def match_pending_operation(state, pipe_name) do
    cond do
      state.operations.read_stdout_or_stderr &&
          pipe_name in [:stdout, :stderr] ->
        {:ok, :read_stdout_or_stderr}

      state.operations.read_stdout &&
          pipe_name == :stdout ->
        {:ok, :read_stdout}

      state.operations.read_stderr &&
          pipe_name == :stderr ->
        {:ok, :read_stderr}

      state.operations.write_stdin &&
          pipe_name == :stdin ->
        {:ok, :write_stdin}

      true ->
        {:error, :no_pending_operation}
    end
  end

  @spec handle_successful_write(State.t(), non_neg_integer(), write_operation()) ::
          :ok | {:noreply, State.t()} | {:error, term}
  defp handle_successful_write(state, written_size, {name, from, bin}) do
    bin_size = byte_size(bin)

    # check if it is partial write
    if written_size < bin_size do
      new_bin = binary_part(bin, written_size, bin_size - written_size)

      case State.put_operation(state, {name, from, new_bin}) do
        {:ok, new_state} ->
          {:noreply, new_state}

        error ->
          error
      end
    else
      :ok
    end
  end

  @spec do_read_any(pid, non_neg_integer(), Pipe.t(), Pipe.t()) ::
          :eof | {:ok, {Pipe.name(), binary}} | {:error, term}
  defp do_read_any(caller, size, primary, secondary) do
    case Pipe.read(primary, size, caller) do
      ret1 when ret1 in [:eof, {:error, :eagain}, {:error, :pipe_closed_or_invalid_caller}] ->
        case {ret1, Pipe.read(secondary, size, caller)} do
          {:eof, :eof} ->
            :eof

          {_, {:ok, bin}} ->
            {:ok, {secondary.name, bin}}

          {ret1, {:error, :pipe_closed_or_invalid_caller}} ->
            ret1

          {_, ret2} ->
            ret2
        end

      {:ok, bin} ->
        {:ok, {primary.name, bin}}

      ret1 ->
        ret1
    end
  end

  @spec validate_read_any_operation(operation) ::
          {:ok, read_any_operation()} | {:error, :invalid_operation}
  defp validate_read_any_operation(operation) do
    case operation do
      {:read_stdout_or_stderr, _from, size} when is_integer(size) and size >= 0 ->
        {:ok, operation}

      _ ->
        {:error, :invalid_operation}
    end
  end

  @spec validate_read_operation(operation) ::
          {:ok, read_operation()} | {:error, :invalid_operation}
  defp validate_read_operation(operation) do
    case operation do
      {:read_stdout, _from, size} when is_integer(size) and size >= 0 ->
        {:ok, operation}

      {:read_stderr, _from, size} when is_integer(size) and size >= 0 ->
        {:ok, operation}

      _ ->
        {:error, :invalid_operation}
    end
  end

  @spec validate_write_operation(operation) ::
          {:ok, write_operation()} | {:error, :invalid_operation}
  defp validate_write_operation(operation) do
    case operation do
      {:write_stdin, _from, bin} when is_binary(bin) ->
        {:ok, operation}

      _ ->
        {:error, :invalid_operation}
    end
  end

  @spec validate_operation(operation) :: {:ok, operation()} | {:error, :invalid_operation}
  defp validate_operation(operation) do
    with {:error, :invalid_operation} <- validate_read_operation(operation),
         {:error, :invalid_operation} <- validate_read_any_operation(operation) do
      validate_write_operation(operation)
    end
  end

  @spec pipe_name(operation()) :: :stdin | :stdout | :stderr
  defp pipe_name({op, _from, _}) do
    case op do
      :write_stdin -> :stdin
      :read_stdout -> :stdout
      :read_stderr -> :stderr
      :read_stdout_or_stderr -> :stdout
    end
  end
end
