defmodule Valimc.Session.ChunkSender do
  @moduledoc """
  Chunk send pacing (VMC-070), as vanilla 26.3's `PlayerChunkSender`.

  Every 50 ms tick adds the client's desired chunks per tick to a quota capped at
  one tick's worth; a batch takes the whole quota. Until the client acknowledges
  its first batch one batch may be unacknowledged, afterwards ten. Each
  acknowledgement carries the client's new desired rate (0.01..64 chunks per tick;
  9 before the first). Ticks are the only refill, so acknowledgements cannot speed
  the stream past that rate.

  The connection never waits for a chunk (VMC-077e): a packet its owner did not
  publish is requested (at most 64 at a time) and its reply kept in `ready`
  until a batch takes it; a block or light change of that chunk drops it.
  """

  @min_rate 0.01
  @max_rate 64.0
  @max_requests 64

  defstruct desired: 9.0,
            quota: 0.0,
            unacknowledged: 0,
            max_unacknowledged: 1,
            requests: :gen_server.reqids_new(),
            requested: MapSet.new(),
            ready: %{}

  @doc "A tick: refill the quota while another batch may go out."
  def tick(%__MODULE__{} = sender) do
    if sender.unacknowledged < sender.max_unacknowledged,
      do: %{sender | quota: min(sender.quota + sender.desired, max(1.0, sender.desired))},
      else: sender
  end

  @doc "How many chunks the next batch may hold now (0 when none may go out)."
  def batch_size(%__MODULE__{} = sender) do
    if sender.unacknowledged < sender.max_unacknowledged and sender.quota >= 1.0,
      do: trunc(sender.quota),
      else: 0
  end

  @doc "A batch of `count` chunks went out."
  def sent(%__MODULE__{} = sender, count) when count > 0,
    do: %{sender | unacknowledged: sender.unacknowledged + 1, quota: sender.quota - count}

  @doc "The client acknowledged a batch; `payload` is its `chunk_batch_received` float."
  def acknowledged(%__MODULE__{} = sender, <<_::32>> = payload) do
    unacknowledged = max(sender.unacknowledged - 1, 0)

    %{
      sender
      | unacknowledged: unacknowledged,
        desired: rate(payload),
        quota: if(unacknowledged == 0, do: 1.0, else: sender.quota),
        max_unacknowledged: 10
    }
  end

  @doc "The frame of `chunk` a reply brought, taken: `{:ok, frame, sender}` or `:error`."
  def take(%__MODULE__{} = sender, chunk) do
    case Map.pop(sender.ready, chunk) do
      {nil, _} -> :error
      {frame, ready} -> {:ok, frame, %{sender | ready: ready}}
    end
  end

  @doc "Request `chunk` from `owner` unless it is requested already or too many are."
  def request(%__MODULE__{} = sender, chunk, owner) do
    if MapSet.member?(sender.requested, chunk) or MapSet.size(sender.requested) >= @max_requests do
      sender
    else
      request = Valimc.World.request_chunk(owner, chunk)

      %{
        sender
        | requests: :gen_server.reqids_add(request, chunk, sender.requests),
          requested: MapSet.put(sender.requested, chunk)
      }
    end
  end

  @doc """
  A message that may answer a request: `{:ok, chunk, sender}` (the frame, if
  any, is now ready) or `:error` when it is not one.
  """
  def response(%__MODULE__{} = sender, message) do
    case :gen_server.check_response(message, sender.requests, true) do
      {result, chunk, requests} ->
        ready =
          case result do
            {:reply, frame} when is_binary(frame) or is_list(frame) ->
              Map.put(sender.ready, chunk, frame)

            _ ->
              sender.ready
          end

        requested = MapSet.delete(sender.requested, chunk)
        {:ok, chunk, %{sender | requests: requests, requested: requested, ready: ready}}

      _ ->
        :error
    end
  end

  @doc "Drop the ready frames of `chunks` (their packets changed, or they left the view)."
  def forget(%__MODULE__{ready: ready} = sender, _chunks) when map_size(ready) == 0, do: sender

  def forget(%__MODULE__{} = sender, chunks),
    do: %{sender | ready: Map.drop(sender.ready, Enum.to_list(chunks))}

  @doc "Abandon every request and ready frame (the player changed dimension)."
  def reset(%__MODULE__{} = sender) do
    for {request, _} <- :gen_server.reqids_to_list(sender.requests),
        do: :erlang.demonitor(request, [:flush])

    %{sender | requests: :gen_server.reqids_new(), requested: MapSet.new(), ready: %{}}
  end

  defp rate(<<desired::float-32>>), do: desired |> max(@min_rate) |> min(@max_rate)
  # Infinities clamp; vanilla treats NaN as the minimum.
  defp rate(<<0::1, 255, 0::23>>), do: @max_rate
  defp rate(<<_::1, 255, _::23>>), do: @min_rate
end
