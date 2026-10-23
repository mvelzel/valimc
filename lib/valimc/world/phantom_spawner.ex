defmodule Valimc.World.PhantomSpawner do
  @moduledoc """
  `PhantomSpawner` (VMC-043b6), the overworld's, run by a group after its
  natural spawns while monsters and phantoms spawn: every one to two
  minutes, from the group's level random, while the sky is dark enough
  (`skyDarken >= 5`) each player who is not spectating, at or above sea
  level under the open sky, may be visited: harder local difficulty makes it
  likelier, and the longer since the player rested (`time_since_rest`, at
  least three days for any chance) the likelier still. One to (difficulty
  + 1) phantoms spawn 20 to 34 blocks above it, up to ten blocks off on
  each axis, where the block is an empty one a mob may spawn in; they
  finalize as natural spawns.

  Vanilla's countdown is the level's; here each group with players counts
  down on its own, as the cat spawner does.
  """
  alias Valimc.Data.{BlockFacts, Blocks, Float32, Grid, JavaRandom}
  alias Valimc.Entity.{Body, Store}
  alias Valimc.World.GameRules

  @phantom "minecraft:phantom"
  @tags Valimc.Protocol.Data.tags()["minecraft:block"]
  @prevent MapSet.new(@tags["minecraft:prevent_mob_spawning_inside"])
  # `EntityType.isBlockDangerous` for a phantom: burning blocks, wither
  # roses, berry bushes, cacti and powder snow.
  @dangerous MapSet.new(
               @tags["minecraft:fire"] ++
                 Enum.map(
                   ~w(lava magma_block lava_cauldron wither_rose sweet_berry_bush cactus powder_snow),
                   &Blocks.id/1
                 )
             )
  @campfires MapSet.new(@tags["minecraft:campfires"])

  @doc """
  One tick of the spawner for `group` (with `rest`, its players as `{x, y,
  z, spectator, time_since_rest}`) and the level `random`: `{countdown,
  random, [{section key, record}]}`.
  """
  def tick(group, random) do
    countdown = Map.get(group.spawning, :phantoms, 0)
    env = group.environment

    cond do
      group.dimension != :overworld or env.difficulty == 0 or
        not GameRules.get(:spawn_monsters) or not GameRules.get(:spawn_phantoms) ->
        {countdown, random, []}

      countdown - 1 > 0 ->
        {countdown - 1, random, []}

      true ->
        {n, random} = JavaRandom.next_int(random, 60)
        countdown = countdown - 1 + (60 + n) * 20

        if env.darken >= 5 do
          {random, made} =
            Enum.reduce(Map.get(group, :rest, []), {random, []}, fn player, {random, made} ->
              {random, more} = visit(group, player, random)
              {random, made ++ more}
            end)

          {countdown, random, made}
        else
          {countdown, random, []}
        end
    end
  end

  defp visit(_group, {_, _, _, true, _}, random), do: {random, []}

  defp visit(group, {x, y, z, false, rest}, random) do
    pos = {floor(x), floor(y), floor(z)}
    {_, py, _} = pos

    if py >= group.environment.sea_level and sees_sky?(group, pos) do
      local = local_difficulty()
      {f, random} = JavaRandom.next_float(random)

      if Valimc.Living.LocalDifficulty.effective(local) > Float32.round(f * 3.0) do
        rest = max(rest, 1)
        {n, random} = JavaRandom.next_int(random, rest)

        if n >= 72_000, do: phantoms(group, pos, random), else: {random, []}
      else
        {random, []}
      end
    else
      {random, []}
    end
  end

  defp phantoms(group, {px, py, pz}, random) do
    {up, random} = JavaRandom.next_int(random, 15)
    {east, random} = JavaRandom.next_int(random, 21)
    {south, random} = JavaRandom.next_int(random, 21)
    {x, y, z} = cell = {px - 10 + east, py + 20 + up, pz - 10 + south}
    view = Valimc.World.View.new(group.dimension)

    case Valimc.World.View.block(view, cell) do
      state when is_integer(state) ->
        if empty?(state) do
          {n, random} = JavaRandom.next_int(random, group.environment.difficulty + 1)
          key = Grid.region_key(Grid.chunk_key(x, z))

          made =
            for _ <- 1..(1 + n) do
              {:ok, body} = Body.spawned(@phantom, :natural)

              {key,
               Store.body_record(body, :crypto.strong_rand_bytes(16), {x + 0.5, y * 1.0, z + 0.5})}
            end

          {random, made}
        else
          {random, []}
        end

      _ ->
        {random, []}
    end
  end

  # `NaturalSpawner.isValidEmptySpawnBlock` for a phantom.
  defp empty?(state) do
    block = Blocks.block_id(state)

    not BlockFacts.flag?(state, :full_collision) and not BlockFacts.flag?(state, :signal_source) and
      BlockFacts.fluid(state).kind == :empty and not MapSet.member?(@prevent, block) and
      not MapSet.member?(@dangerous, block) and not lit_campfire?(state, block)
  end

  defp lit_campfire?(state, block),
    do: MapSet.member?(@campfires, block) and {"lit", "true"} in Blocks.properties(state)

  # `canSeeSky`: full sky light at the player's block.
  defp sees_sky?(group, {x, _, z} = pos) do
    case group.sections[Grid.region_key(Grid.chunk_key(x, z))] do
      %{blocks: blocks} ->
        match?({15, _}, Valimc.World.Blocks.light(blocks, pos))

      _ ->
        false
    end
  end

  defp local_difficulty do
    {difficulty, _} = Valimc.World.Clock.difficulty()
    level = elem({:peaceful, :easy, :normal, :hard}, difficulty.level)
    Valimc.Living.LocalDifficulty.at(level, Valimc.World.Clock.day_ticks())
  end
end
