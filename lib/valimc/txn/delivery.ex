defmodule Valimc.Txn.Delivery do
  @moduledoc """
  One bounded destination attempt for a durable source intent (VMC-064).

  The source owner keeps its intent until it holds destination proof; an attempt
  only carries the intent once. It runs in the bounded `Valimc.TransferWorkers`
  pool and reports `message.(worker, token, result)` to the owner. An attempt is
  identified by its token, so late or foreign reports are ignored, and an
  optional deadline makes a stuck destination retryable. Whether a failed
  attempt is simply made again is the error's class (`Valimc.Error`).
  """

  @type job :: %{
          pid: pid(),
          monitor: reference(),
          token: reference(),
          timer: reference() | nil
        }

  @doc """
  Start `deliver.()` in a worker. Options: `:link` links the worker to the owner
  (region-sourced attempts die with their owner); `:deadline` (ms) sends
  `deadline_message.(token)` to the owner when the attempt overruns.
  """
  def start(owner, message, deliver, opts \\ []) do
    token = Keyword.get_lazy(opts, :token, &make_ref/0)
    link = Keyword.get(opts, :link, false)

    case Task.Supervisor.start_child(
           Valimc.TransferWorkers,
           Valimc.Dimension.bind(fn ->
             if link, do: Process.link(owner)
             send(owner, message.(self(), token, deliver.()))
           end)
         ) do
      {:ok, worker} ->
        timer =
          case Keyword.get(opts, :deadline) do
            nil -> nil
            ms -> Process.send_after(owner, Keyword.fetch!(opts, :deadline_message).(token), ms)
          end

        {:ok, %{pid: worker, monitor: Process.monitor(worker), token: token, timer: timer}}

      {:error, _} ->
        Valimc.Error.retry(:transfer_workers_busy)
    end
  catch
    # The pool itself is restarting.
    :exit, _ -> Valimc.Error.retry(:transfer_workers_busy)
  end

  @doc "Whether a report belongs to this attempt."
  def current?(%{pid: pid, token: token}, pid, token), do: true
  def current?(_, _, _), do: false

  @doc "The attempt reported or failed: stop its timer and monitor."
  def finish(%{monitor: monitor, timer: timer}) do
    if timer, do: Process.cancel_timer(timer)
    Process.demonitor(monitor, [:flush])
    :ok
  end

  @doc "Give up on a running attempt (deadline, shutdown)."
  def abort(%{pid: pid} = job) do
    finish(job)
    Process.exit(pid, :kill)
    :ok
  end
end
