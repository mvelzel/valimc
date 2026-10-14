defmodule Valimc.CreativeInput do
  @moduledoc "Bounded connection-local deferred commands and vanilla creative-drop admission."
  defstruct queue: :queue.new(), queued: 0, bytes: 0, level: 0, tick: 0
  @max_commands 160
  @max_bytes 524_288

  def new(tick), do: %__MODULE__{tick: tick}

  def charge(input, tick) when is_integer(tick) do
    tick = max(tick, input.tick)
    level = max(input.level - (tick - input.tick), 0)
    input = %{input | tick: tick, level: level}

    if level < 1480,
      do: {:ok, %{input | level: level + 20}},
      else: {:throttled, input}
  end

  def push(input, command, payload_bytes) when is_integer(payload_bytes) and payload_bytes >= 0 do
    cost = payload_bytes + 64

    if input.queued < @max_commands and input.bytes + cost <= @max_bytes do
      {:ok,
       %{
         input
         | queue: :queue.in({command, cost}, input.queue),
           queued: input.queued + 1,
           bytes: input.bytes + cost
       }}
    else
      {:error, :creative_queue_limit}
    end
  end

  def pop(input) do
    case :queue.out(input.queue) do
      {{:value, {command, cost}}, queue} ->
        {:ok, command,
         %{input | queue: queue, queued: input.queued - 1, bytes: input.bytes - cost}}

      {:empty, _} ->
        :empty
    end
  end

  def clear(input), do: %{input | queue: :queue.new(), queued: 0, bytes: 0}
end
