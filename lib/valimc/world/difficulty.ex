defmodule Valimc.World.Difficulty do
  @moduledoc "Native world difficulty/lock state; gameplay effects and hardcore are separate."
  alias Valimc.Protocol.Packets
  defstruct level: 1, locked: false

  def valid?(%__MODULE__{level: level, locked: locked}),
    do: is_integer(level) and level in 0..3 and is_boolean(locked)

  def valid?(_), do: false

  def change(state, level, force \\ false)

  def change(%__MODULE__{} = state, level, force)
      when is_integer(level) and level in 0..3 and is_boolean(force) do
    if state.locked and not force,
      do: {:ok, state},
      else: {:ok, %{state | level: level}}
  end

  def change(_, _, _), do: {:error, :invalid_difficulty_change}

  def lock(%__MODULE__{} = state, locked) when is_boolean(locked),
    do: {:ok, %{state | locked: locked}}

  def lock(_, _), do: {:error, :invalid_difficulty_change}

  def cache(state, {state, _} = previous), do: previous
  def cache(state, _), do: {state, Packets.difficulty(state)}
end
