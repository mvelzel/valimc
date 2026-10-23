defmodule Valimc.Player.Trampling do
  @moduledoc """
  A player's landing that tramples farmland (VMC-039a, `FarmlandBlock.fallOn`
  with `Valimc.Blocks.Farmland.tramples?/4`; a player may always trample, as
  ValiMC has no spawn protection): the farmland's owner turns it to dirt,
  then a player standing in the dirt's top sixteenth goes up onto it
  (`Block.pushEntitiesUp`, a teleport that keeps its motion). Turtle eggs a
  player lands or stands on may lose one (VMC-043e, `TurtleEggBlock`).
  """
  alias Valimc.Blocks.Farmland
  alias Valimc.Data.{Grid, PlayerPose}
  alias Valimc.World.Region

  @turtle_eggs MapSet.new(Valimc.Data.Blocks.states("turtle_egg"))

  @doc "After a move that landed on `{state, distance, cell}` (or nil)."
  def land(state, nil), do: step_on(state)

  # `TurtleEggBlock.fallOn`: one chance in three it loses an egg (VMC-043e).
  def land(%{life_stage: :alive} = state, {block, distance, {x, y, z} = cell}) do
    if MapSet.member?(@turtle_eggs, block), do: crush(state, cell, 3)
    state = step_on(state)
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

  # `TurtleEggBlock.stepOn` on the ground, not sneaking: one chance in a
  # hundred the eggs it stands on lose one (VMC-043e).
  defp step_on(%{life_stage: :alive, player: player} = state) do
    {x, y, z} = {player.x, player.y, player.z}
    cell = {floor(x), floor(y - 0.2), floor(z)}

    with true <- player.motion.on_ground,
         false <-
           Valimc.Player.Input.pressed?(Map.get(player, :input, %Valimc.Player.Input{}), :shift),
         block when block != nil <-
           Valimc.World.View.block(Valimc.World.View.new(player.dimension), cell),
         true <- MapSet.member?(@turtle_eggs, block) do
      crush(state, cell, 100)
    end

    state
  end

  defp step_on(state), do: state

  defp crush(state, {x, _, z} = cell, odds) do
    with {:ok, owner} <-
           Valimc.World.existing_owner(Grid.section(state.player.dimension, Grid.chunk_key(x, z))),
         do: Region.crush_egg(owner, cell, odds)
  end

  defp push_up(%{player: player} = state, top) do
    if player.y < top and player.y > top - 1.0,
      do: Valimc.Player.Movement.relocate(state, %{player | y: top}, false),
      else: state
  end

  defp roll, do: (:rand.uniform(16_777_216) - 1) / 16_777_216
end
