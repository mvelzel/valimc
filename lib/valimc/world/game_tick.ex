defmodule Valimc.World.GameTick do
  @moduledoc """
  The world's game tick (VMC-077j): the world clock's game time, published in
  an atomic counter so every group process numbers its ticks from it. Vanilla
  keeps one game time for the whole server; groups that merge therefore share
  their tick numbers and their scheduled ticks need no offsets.
  """
  @key {__MODULE__, :counter}

  @doc "Create the counter; the application owns it."
  def init! do
    :persistent_term.put(@key, :atomics.new(1, signed: true))
    :ok
  end

  @doc "The current game tick (0 before the world clock publishes one)."
  def current do
    case :persistent_term.get(@key, nil) do
      nil -> 0
      counter -> :atomics.get(counter, 1)
    end
  end

  @doc "The world clock's game time moved to `tick`."
  def put(tick) do
    with counter when counter != nil <- :persistent_term.get(@key, nil),
         do: :atomics.put(counter, 1, tick)

    :ok
  end
end
