defmodule Valimc.Session.Inputs do
  @moduledoc """
  A hosted session's play input (VMC-077i3): the packets its connection
  forwards, applied in arrival order between the group's ticks, as vanilla's
  server thread runs queued packet tasks between ticks. A queue holds them
  only while a packet must wait: a block use's fallback item use waits for the
  block menu decision before it (`resume_inputs` continues). The connection's
  rate limits bound what arrives; the queue holds at most #{1024} packets.
  """
  import Valimc.Net.Codec, only: [reject: 2]
  alias Valimc.Net.Serverbound
  alias Valimc.Protocol.Data

  @limit 1024
  @use_item Data.id(:play, :serverbound, "use_item")

  @doc "Queue one forwarded packet and apply what may run."
  def receive(state, id, payload) do
    if :queue.len(state.inputs) >= @limit, do: reject(state, "Too many pending packets")
    run(%{state | inputs: :queue.in({id, payload}, state.inputs)})
  end

  @doc "Apply queued packets until one must wait."
  def run(state) do
    case :queue.peek(state.inputs) do
      :empty ->
        state

      {:value, {@use_item, _}} when is_map(state.table_job) and state.table_job.kind == :open ->
        state

      {:value, _} ->
        apply_next(state)
    end
  end

  defp apply_next(state) do
    {{:value, {id, payload}}, rest} = :queue.out(state.inputs)
    run(Serverbound.handle_packet(%{state | inputs: rest}, id, payload))
  end
end
