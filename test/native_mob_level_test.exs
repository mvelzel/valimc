defmodule Valimc.NativeMobLevelTest do
  @moduledoc """
  The native mob level and sensing (VMC-081d, `valimc_core::mobs::level`
  and `sensing`) answer as `Valimc.AI.World` does over generated terrain
  held in a region's store: block predicates, light, biomes, heights,
  fitting and water boxes, lines of sight, and a zombie's targeting
  queries over sensed players and mobs.
  """
  use ExUnit.Case, async: true
  alias Valimc.AI.{Mind, Self, Spatial, World}
  alias Valimc.Native
  alias Valimc.Worldgen.Generator

  @seed 20_261_029
  @zoom_seed -4_172_144_997_902_289_642
  @chunks for cx <- 0..2, cz <- 0..2, do: {cx, cz}

  setup_all do
    Valimc.AI.NativeFacts.install!()
    images = Valimc.World.Blocks.lit_images(Generator.columns({:vanilla, @seed}, @chunks), true)
    size = Valimc.Data.Grid.region_size()
    absent = for cx <- 0..(size - 1), cz <- 0..(size - 1), {cx, cz} not in @chunks, do: {cx, cz}
    {:ok, blocks} = Valimc.World.Blocks.new({0, 0}, %{}, images, MapSet.new(absent))
    %{blocks: blocks}
  end

  defp world(blocks, darken \\ 0) do
    read = fn {x, y, z} ->
      case Native.get_blocks(blocks.ref, <<x::32-signed, y::32-signed, z::32-signed>>) do
        {:ok, <<state::16>>} -> state
        _ -> nil
      end
    end

    %World{
      read: read,
      light: &Valimc.World.Blocks.light(blocks, &1),
      biome: &Valimc.World.Blocks.biome(blocks, @zoom_seed, &1),
      darken: darken
    }
  end

  defp surface(world, x, z), do: World.motion_blocking(world, x, z)

  test "block predicates, light and biomes", %{blocks: blocks} do
    for darken <- [0, 11] do
      world = world(blocks, darken)

      cells =
        for x <- -1..48//3,
            z <- -1..48//4,
            y <- [-65, 320 | Enum.to_list(40..110//3)],
            do: {x, y, z}

      expected =
        for p <- cells do
          {World.block(world, p), World.air?(world, p), World.solid?(world, p),
           World.collides?(world, p), World.fluid(world, p), World.conductor?(world, p),
           World.solid_render?(world, p), World.light(world, p), World.sees_sky?(world, p),
           World.biome(world, p)}
        end

      native =
        Native.mob_parity_level(blocks.ref, @zoom_seed, darken, for(p <- cells, do: {:cell, p}))

      for {p, e, n} <- Enum.zip([cells, expected, native]), do: assert({p, n} == {p, e})
      assert Enum.any?(expected, &(elem(&1, 4) == :water))
      if darken > 0, do: assert(Enum.any?(expected, &(elem(&1, 7) not in [0.0, 1.0])))
      assert Enum.any?(expected, &(elem(&1, 0) != nil and elem(&1, 3) and not elem(&1, 1)))
    end
  end

  test "heights and boxes", %{blocks: blocks} do
    world = world(blocks)
    columns = for x <- -2..49//5, z <- -2..49//5, do: {x, z}

    native =
      Native.mob_parity_level(
        blocks.ref,
        @zoom_seed,
        0,
        for({x, z} <- columns, do: {:motion_blocking, x, z})
      )

    assert native == for({x, z} <- columns, do: surface(world, x, z))

    bodies =
      for {x, z} <- columns,
          x in 0..47 and z in 0..47,
          {w, h} <- [{0.6, 1.95}, {0.9, 1.4}, {1.3964844, 1.4}],
          dy <- [-1.5, -0.6, 0.0, 0.3, 1.0],
          dx <- [0.5, 0.05],
          do: %{x: x + dx, y: surface(world, x, z) + dy, z: z + 0.5, width: w, height: h}

    queries = for b <- bodies, op <- [:fits, :in_water], do: {op, World.box(b)}

    expected =
      for b <- bodies, op <- [:fits, :in_water] do
        if op == :fits, do: World.fits?(world, World.box(b)), else: World.in_water?(world, b)
      end

    assert Native.mob_parity_level(blocks.ref, @zoom_seed, 0, queries) == expected
    assert Enum.any?(expected) and not Enum.all?(expected)
  end

  test "lines of sight through collision shapes", %{blocks: blocks} do
    world = world(blocks)
    :rand.seed(:exsss, {7, 11, 13})

    point = fn ->
      {x, z} = {:rand.uniform() * 46.0 + 1.0, :rand.uniform() * 46.0 + 1.0}
      {x, surface(world, floor(x), floor(z)) + :rand.uniform() * 6.0 - 2.5, z}
    end

    pairs =
      for _ <- 1..600 do
        {fx, fy, fz} = from = point.()
        to = if :rand.uniform() < 0.5, do: point.(), else: {fx + 3.0, fy + 0.5, fz - 2.0}
        {from, to}
      end ++ [{{1.0, 70.0, 1.0}, {1.0, 70.0, 1.0}}, {{1.0, 300.0, 1.0}, {140.0, 300.0, 1.0}}]

    expected =
      for {{fx, fy, fz}, {tx, ty, tz}} <- pairs do
        World.line_of_sight?(%Self{x: fx, y: fy, z: fz, eye: 0.0, world: world}, %{
          x: tx,
          y: ty,
          z: tz,
          eye: 0.0
        })
      end

    assert Native.mob_parity_sight(blocks.ref, pairs) == expected
    assert Enum.count(expected, & &1) in 50..550
  end

  defp player(n, {x, y, z}, options) do
    Map.merge(
      %{
        kind: :player,
        uuid: <<n::128>>,
        id: n,
        x: x,
        y: y,
        z: z,
        yaw: 0.0,
        pitch: 0.0,
        eye: 1.62,
        width: 0.6,
        height: 1.8,
        mode: :survival,
        invulnerable: false,
        alive: true,
        crouching: false,
        swimming: false,
        invisible: false,
        armor_cover: 0.0,
        movement: {0.0, 0.0, 0.0},
        velocity: {0.0, 0.0, 0.0},
        health: 20.0,
        effects: MapSet.new(),
        equipment: %{mainhand: nil, offhand: nil, head: nil, chest: nil, legs: nil, feet: nil}
      },
      Map.new(options)
    )
  end

  defp mob(n, type, {x, y, z}, alive) do
    {w, h, eye} =
      case type do
        "minecraft:cow" -> {0.9, 1.4, 1.3}
        "minecraft:zombie" -> {0.6, 1.95, 1.74}
        "minecraft:ghast" -> {4.0, 4.0, 2.6}
      end

    %{
      kind: :mob,
      uuid: <<n::128>>,
      id: n,
      type: type,
      x: x,
      y: y,
      z: z,
      eye: eye,
      width: w,
      height: h,
      alive: alive,
      invulnerable: n == 17
    }
  end

  test "targeting, nearest entities and mobs in boxes", %{blocks: blocks} do
    base = world(blocks)
    :rand.seed(:exsss, {3, 5, 8})

    at = fn ->
      {x, z} = {:rand.uniform() * 40.0 + 4.0, :rand.uniform() * 40.0 + 4.0}
      {x, surface(base, floor(x), floor(z)) * 1.0, z}
    end

    head = Valimc.Protocol.ItemTypes.id("minecraft:zombie_head")

    players =
      for n <- 1..12 do
        options =
          case rem(n, 6) do
            0 ->
              [mode: :creative, invulnerable: true]

            1 ->
              [crouching: true]

            2 ->
              [invisible: true, armor_cover: 0.5]

            3 ->
              [
                equipment: %{
                  mainhand: nil,
                  offhand: nil,
                  head: head,
                  chest: nil,
                  legs: nil,
                  feet: nil
                }
              ]

            4 ->
              [mode: :spectator]

            _ ->
              []
          end

        player(1000 + n, at.(), options)
      end

    types = ~w(minecraft:cow minecraft:zombie minecraft:ghast)
    mobs = for n <- 1..40, do: mob(n, Enum.at(types, rem(n, 3)), at.(), rem(n, 7) != 0)

    conditions =
      for combat <- [true, false],
          range <- [-1.0, 8.0, 24.0],
          sight <- [true, false],
          invisible <- [true, false],
          do: {combat, range, sight, invisible}

    boxes =
      for _ <- 1..6,
          do:
            World.inflate(
              World.box(%{
                x: elem(at.(), 0),
                y: 70.0,
                z: elem(at.(), 2),
                width: 0.6,
                height: 1.95
              }),
              10.0,
              40.0,
              10.0
            )

    queries =
      Enum.flat_map(conditions, fn c ->
        [{:nearest_player, c, at.()}] ++
          for(i <- 0..11, do: {:test, {:player, i}, c}) ++
          for(i <- 0..39//3, do: {:test, {:mob, i}, c}) ++
          for(
            b <- Enum.take(boxes, 2),
            select <- [:any, ["minecraft:cow"]],
            do: {:nearest_mob, select, b, c, at.()}
          )
      end) ++
        for(i <- 0..11, do: {:visibility, i}) ++
        Enum.flat_map(Enum.take(mobs, 20), fn m ->
          {x, y, z} = at.()

          [{:resense, m.uuid, {x, y, z}, rem(m.id, 2) == 0}] ++
            for(
              b <- boxes,
              select <- [:any, ["minecraft:cow"], ["minecraft:cow", "minecraft:ghast"]],
              do: {:mobs_in, select, b}
            )
        end) ++
        for(p <- players, do: {:target, {:player, p.uuid}}) ++
        for(m <- mobs, do: {:target, {:mob, m.uuid}})

    for difficulty <- [:normal, :peaceful] do
      world = %{
        base
        | players: players,
          mobs: mobs,
          by_type: Enum.group_by(mobs, & &1.type),
          index: Map.new(mobs, &{&1.uuid, &1}),
          spatial: Spatial.new(mobs),
          difficulty: difficulty
      }

      me = %Self{
        uuid: <<0::128>>,
        type: "minecraft:zombie",
        x: 24.5,
        y: surface(base, 24, 24) * 1.0,
        z: 24.5,
        eye: 1.74,
        mind: %Mind{},
        world: world
      }

      {expected, _} = Enum.map_reduce(queries, me, &answer/2)

      native =
        Native.mob_parity_sensing(
          blocks.ref,
          difficulty,
          {me.uuid, me.type, {me.x, me.y, me.z}, me.eye},
          players,
          mobs,
          queries
        )

      for {q, e, n} <- Enum.zip([queries, expected, native]), do: assert({q, n} == {q, e})
      assert Enum.any?(expected, &(&1 == true)) and Enum.any?(expected, &(&1 == false))
    end
  end

  defp conditions({combat, range, sight, invisible}),
    do: World.conditions(combat, range: range, sight: sight, invisible: invisible)

  defp uuid(nil), do: nil
  defp uuid(entity), do: entity.uuid

  defp answer({:test, {kind, i}, c}, self) do
    target =
      Enum.at(if(kind == :player, do: self.world.players, else: World.mob_list(self.world)), i)

    World.test(self, target, conditions(c))
  end

  defp answer({:visibility, i}, self),
    do: {World.visibility(Enum.at(self.world.players, i), self.type), self}

  defp answer({:nearest_player, c, {x, y, z}}, self) do
    {p, self} = World.nearest_player(self, conditions(c), x, y, z)
    {uuid(p), self}
  end

  defp answer({:nearest_mob, select, box, c, {x, y, z}}, self) do
    {m, self} = World.nearest_mob(self, select(select), box, conditions(c), x, y, z)
    {uuid(m), self}
  end

  defp answer({:mobs_in, select, box}, self),
    do: {Enum.map(World.mobs_in(self, select(select), box), & &1.uuid), self}

  defp answer({:resense, uuid, {x, y, z}, alive}, self) do
    world = World.resense(self.world, uuid, &%{&1 | x: x, y: y, z: z, alive: alive})
    {true, %{self | world: world}}
  end

  defp answer({:target, ref}, self),
    do: {uuid(World.target(%{self | mind: %{self.mind | target: ref}})), self}

  defp select(:any), do: fn _ -> true end
  defp select(types), do: types
end
