defmodule Valimc.Player.Trampling do
  @moduledoc """
  A player's landing that tramples farmland (VMC-039a, `FarmlandBlock.fallOn`
  with `Valimc.Blocks.Farmland.tramples?/4`; a player may always trample, as
  ValiMC has no spawn protection): the farmland's owner turns it to dirt,
  then a player standing in the dirt's top sixteenth goes up onto it
  (`Block.pushEntitiesUp`, a teleport that keeps its motion).
  """
  alias Valimc.Blocks.Farmland
  alias Valimc.Data.{Grid, PlayerPose}
  alias Valimc.World.Region

  @doc "After a move that landed on `{state, distance, cell}` (or nil)."
  def land(state, nil), do: state

  def land(%{life_stage: :alive} = state, {block, distance, {x, y, z} = cell}) do
    {:ok, size} = PlayerPose.dimensions(state.player.pose)

    with true <- Farmland.tramples?(block, distance, {size["width"], size["height"]}, roll()),
         {:ok, owner} <-
           Valimc.World.existing_owner(Grid.section(state.player.dimension, Grid.chunk_key(x, z))),
         {:ok, 1} <- Region.bucket(owner, {:trample, cell}) do
      push_up(state, y + 1.0)
    else
      _ -> state
    end
  end

  def land(state, _landed), do: state

  defp push_up(%{player: player} = state, top) do
    if player.y < top and player.y > top - 1.0,
      do: Valimc.Player.Movement.relocate(state, %{player | y: top}, false),
      else: state
  end

  defp roll, do: (:rand.uniform(16_777_216) - 1) / 16_777_216
end
