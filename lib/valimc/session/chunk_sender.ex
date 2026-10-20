defmodule Valimc.Session.ChunkSender do
  @moduledoc """
  Chunk send pacing (VMC-070), as vanilla 26.3's `PlayerChunkSender`.

  Every 50 ms tick adds the client's desired chunks per tick to a quota capped at
  one tick's worth; a batch takes the whole quota. Until the client acknowledges
  its first batch one batch may be unacknowledged, afterwards ten. Each
  acknowledgement carries the client's new desired rate (0.01..64 chunks per tick;
  9 before the first). Ticks are the only refill, so acknowledgements cannot speed
  the stream past that rate.
  """

  @min_rate 0.01
  @max_rate 64.0

  defstruct desired: 9.0, quota: 0.0, unacknowledged: 0, max_unacknowledged: 1

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

  defp rate(<<desired::float-32>>), do: desired |> max(@min_rate) |> min(@max_rate)
  # Infinities clamp; vanilla treats NaN as the minimum.
  defp rate(<<0::1, 255, 0::23>>), do: @max_rate
  defp rate(<<_::1, 255, _::23>>), do: @min_rate
end
