defmodule Valimc.World.Trades do
  @moduledoc """
  A merchant's offers made in its group (VMC-044b1): `updateTrades` draws
  each trade set the merchant's profession has at its level (a wandering
  trader's three sets) from the set's server-wide random sequence, borrowed
  from `Valimc.World.RandomSequences` for the one native draw.

  An exploration map needs the structure its search finds; `structures`
  answers known searches (`{tag, {x, y, z} | nil}`). One it lacks stops the
  draw before it takes anything from the sequence and answers `{:locate,
  tag, radius}`: the group searches as a job and draws again with the
  answer. Map ids are not allocated yet (maps are VMC-051): every map takes
  id 0, as container loot's do.
  """
  alias Valimc.Menus.Offers
  alias Valimc.World.RandomSequences

  @doc """
  The offers `updateTrades` adds for a merchant: `%{profession: name | nil
  (a wandering trader), level: n, villager_type: name, position: {x, y,
  z}}`. `{:ok, offers}`, `{:locate, tag, radius}` or `{:error, reason}`.
  """
  def draw(merchant, structures \\ [], server \\ RandomSequences) do
    Enum.reduce_while(Offers.sets(merchant.profession, merchant.level), {:ok, []}, fn
      {set, sequence}, {:ok, offers} ->
        case draw_set(set, sequence, merchant, structures, server) do
          {:ok, more} -> {:cont, {:ok, offers ++ more}}
          other -> {:halt, other}
        end
    end)
  end

  defp draw_set(set, nil, _merchant, _structures, _server),
    do: {:error, {:invalid, {:trade_set_without_sequence, set}}}

  defp draw_set(set, sequence, merchant, structures, server) do
    result =
      RandomSequences.with(server, sequence, fn state ->
        case Offers.draw(set, state, merchant.villager_type, merchant.position, structures, 0) do
          {:ok, offers, state, _next_map} -> {{:ok, offers}, state}
          other -> {other, :unchanged}
        end
      end)

    case result do
      {:ok, answer} -> answer
      {:error, _} = error -> error
    end
  end
end
