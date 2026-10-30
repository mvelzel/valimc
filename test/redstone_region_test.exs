defmodule Valimc.RedstoneRegionTest do
  @moduledoc """
  Redstone in region owners (VMC-047a, VMC-048a): a player's use reaches the
  block rules, scheduled ticks run by block, entities press plates once a
  tick, power primes TNT as an entity, daylight detectors follow the day, a
  comparator reads a chest's fullness and keeps its output, a repeater's
  use cycles its delay, and an update past a group's edge stops there until
  the groups merge. The rules themselves are `check_redstone.exs`'s.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    a = {96_000 + rem(nonce, 3_333) * 3, 2300}
    b = {elem(a, 0) + 1, 2300}
    base = Path.join(System.tmp_dir!(), "valimc-redstone-#{nonce}")
    TestScope.isolate([a, b], world_path: base, region_ticks: :manual, regionizer: false)

    on_exit(fn ->
      for key <- [a, b],
          {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, {pa, ea}} = Valimc.TestWorld.owner(a)
    {:ok, {pb, eb}} = Valimc.TestWorld.owner(b)
    TestScope.simulate({pa, ea}, a)
    TestScope.simulate({pb, eb}, b)
    {ax, az} = a
    %{a: a, b: b, owner: {pa, ea}, pa: pa, pb: pb, eb: eb, x: ax * 128, z: az * 128}
  end

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp props(position), do: Map.new(BlockRegistry.properties(Valimc.TestBlocks.get(position)))

  defp block(position),
    do: BlockRegistry.name(BlockRegistry.block_id(Valimc.TestBlocks.get(position)))

  defp state(name, props), do: BlockRegistry.state(name, props)

  defp press(owner, {x, y, z} = position, mode \\ :survival) do
    grant = %{
      kind: :open,
      mode: mode,
      eye: {x + 0.5, y + 1.6, z - 1.5},
      hand: :main,
      secondary: false,
      main: false,
      off: false,
      yaw: 0.0,
      expires: Valimc.TestRegion.grant_expires(200)
    }

    Region.menu(owner, self(), position, grant)
  end

  # The test world's floor is at y 63.
  test "a lever lights a lamp and a button opens an iron door for a while", ctx do
    {x, z} = {ctx.x + 20, ctx.z + 20}
    lamp = {x, 64, z}
    lever = {x + 1, 64, z}

    set(ctx.owner, %{
      lamp => BlockRegistry.default_state("redstone_lamp"),
      lever => state("lever", %{"face" => "floor", "facing" => "north"})
    })

    assert press(ctx.owner, lever) == :used
    assert props(lever)["powered"] == "true"
    assert props(lamp)["lit"] == "true"
    # Unlit four ticks after the lever goes off.
    assert press(ctx.owner, lever) == :used
    assert props(lamp)["lit"] == "true"
    assert {:ok, _} = Region.step(ctx.owner, 4)
    assert props(lamp)["lit"] == "false"

    door = %{"facing" => "north", "hinge" => "left", "open" => "false", "powered" => "false"}
    {dx, dz} = {x + 10, z}
    button = {dx + 1, 64, dz}

    set(ctx.owner, %{
      {dx, 64, dz} => state("iron_door", Map.put(door, "half", "lower")),
      {dx, 65, dz} => state("iron_door", Map.put(door, "half", "upper")),
      button => state("stone_button", %{"face" => "floor", "facing" => "north"})
    })

    # A hand does not open an iron door; the use passes on.
    refute press(ctx.owner, {dx, 64, dz}) == :used
    assert press(ctx.owner, button) == :used
    assert {props({dx, 64, dz})["open"], props({dx, 65, dz})["open"]} == {"true", "true"}
    # A stone button stays pressed 20 ticks.
    assert {:ok, _} = Region.step(ctx.owner, 19)
    assert props({dx, 64, dz})["open"] == "true"
    assert {:ok, _} = Region.step(ctx.owner, 1)
    assert props(button)["powered"] == "false"
    assert {props({dx, 64, dz})["open"], props({dx, 65, dz})["open"]} == {"false", "false"}
  end

  test "an item on a plate powers it until it is gone; power primes TNT", ctx do
    {x, z} = {ctx.x + 40, ctx.z + 40}
    plate = {x, 64, z}
    lamp = {x + 1, 64, z}

    set(ctx.owner, %{
      plate => BlockRegistry.default_state("oak_pressure_plate"),
      lamp => BlockRegistry.default_state("redstone_lamp")
    })

    {:ok, _} = Region.create_item(ctx.owner, ItemStack.new("stone"), {x + 0.5, 64.0, z + 0.5})
    assert {:ok, _} = Region.step(ctx.owner, 2)
    assert props(plate)["powered"] == "true"
    assert props(lamp)["lit"] == "true"

    tnt = {x + 5, 64, z}
    set(ctx.owner, %{tnt => BlockRegistry.default_state("tnt")})
    set(ctx.owner, %{{x + 6, 64, z} => BlockRegistry.default_state("redstone_block")})
    assert block(tnt) == "air"

    assert Enum.any?(Valimc.TestRegion.section(ctx.owner).entities.store.entries, fn
             {_, %{kind: :object, body: %{type: "minecraft:tnt"}}} -> true
             _ -> false
           end)
  end

  test "a native mob on a stone plate powers it (its section packs its box)", ctx do
    {x, z} = {ctx.x + 30, ctx.z + 70}
    plate = {x, 64, z}

    set(ctx.owner, %{
      {x, 63, z} => BlockRegistry.default_state("stone"),
      plate => BlockRegistry.default_state("stone_pressure_plate")
    })

    {:ok, cow} = Valimc.Entity.Body.new("minecraft:cow")
    cow = %{cow | mob: %{cow.mob | no_ai: true}}
    record = Valimc.Entity.Store.body_record(cow, <<77::128>>, {x + 0.5, 64.0, z + 0.5})
    :ok = Region.drop_items(ctx.owner, [record])
    store = Valimc.TestRegion.section(ctx.owner).entities.store
    assert Enum.any?(store.entries, fn {_, e} -> Valimc.Entity.Store.native_entry?(e) end)
    assert {:ok, _} = Region.step(ctx.owner, 2)
    assert props(plate)["powered"] == "true"
  end

  test "a daylight detector reads the sky every twentieth tick; an adventurer cannot invert it",
       ctx do
    {x, y, z} = detector = {ctx.x + 60, 64, ctx.z + 60}
    stone = BlockRegistry.default_state("stone")
    # Walled in and roofed over, it sees no sky at any time of day.
    box =
      for {dx, dy, dz} <- [{-1, 0, 0}, {1, 0, 0}, {0, 0, -1}, {0, 0, 1}, {0, 1, 0}],
          into: %{},
          do: {{x + dx, y + dy, z + dz}, stone}

    set(ctx.owner, Map.put(box, detector, BlockRegistry.default_state("daylight_detector")))
    refute press(ctx.owner, detector, :adventure) == :used
    assert press(ctx.owner, detector) == :used
    assert props(detector) == %{"inverted" => "true", "power" => "15"}
    # Opened to the morning sky (a fresh world's clock), its next update
    # finds full daylight, which an inverted detector turns off.
    set(ctx.owner, %{{x, y + 1, z} => BlockRegistry.default_state("air")})
    assert props(detector)["power"] == "15"
    assert {:ok, _} = Region.step(ctx.owner, 20)
    assert props(detector)["power"] == "0"
  end

  test "a comparator reads a chest's fullness; a repeater's use cycles its delay", ctx do
    {x, z} = {ctx.x + 80, ctx.z + 20}
    {chest, comparator, lamp} = {{x, 64, z}, {x + 1, 64, z}, {x + 2, 64, z}}

    set(ctx.owner, %{
      chest =>
        state("chest", %{"facing" => "north", "type" => "single", "waterlogged" => "false"}),
      comparator =>
        state("comparator", %{"facing" => "west", "mode" => "compare", "powered" => "false"}),
      lamp => BlockRegistry.default_state("redstone_lamp")
    })

    assert Valimc.TestRegion.section(ctx.owner).comparators[comparator] == 0

    # Ten full stacks of 27 slots: `lerpDiscrete(10 / 27, 0, 15)` is 6.
    fill = fn slots ->
      Valimc.TestRegion.replace_section(ctx.owner, fn section ->
        alias Valimc.World.Containers

        {:ok, entry} =
          Containers.observe(section.containers, chest)
          |> case do
            :error -> Containers.create(section.containers, section.key, chest, 3)
            {:ok, entry} -> {:ok, section.containers, entry}
          end
          |> then(fn {:ok, containers, entry} -> {:ok, {containers, entry}} end)

        {containers, entry} = entry
        {:ok, containers, _} = Containers.replace(containers, chest, entry.revision, slots)
        %{section | containers: containers}
      end)
    end

    stone = ItemStack.new("stone", 64)
    fill.(List.to_tuple(List.duplicate(stone, 10) ++ List.duplicate(nil, 17)))
    # Heard at the next block phase, then the comparator's two ticks.
    assert {:ok, _} = Region.step(ctx.owner, 3)
    assert Valimc.TestRegion.section(ctx.owner).comparators[comparator] == 6
    assert props(comparator)["powered"] == "true"
    assert props(lamp)["lit"] == "true"

    fill.(Tuple.duplicate(nil, 27))
    assert {:ok, _} = Region.step(ctx.owner, 7)
    assert Valimc.TestRegion.section(ctx.owner).comparators[comparator] == 0
    assert props(lamp)["lit"] == "false"

    repeater = {x, 64, z + 3}

    set(ctx.owner, %{
      repeater =>
        state("repeater", %{
          "facing" => "north",
          "delay" => "1",
          "locked" => "false",
          "powered" => "false"
        })
    })

    assert press(ctx.owner, repeater) == :used
    assert props(repeater)["delay"] == "2"
    refute press(ctx.owner, repeater, :adventure) == :used
    # Its block entity goes with the comparator.
    set(ctx.owner, %{comparator => BlockRegistry.default_state("air")})
    refute Map.has_key?(Valimc.TestRegion.section(ctx.owner).comparators, comparator)
  end

  test "an update past the group's edge stops there; after a merge it reaches", ctx do
    edge = ctx.x + 128
    z = ctx.z + 9
    lever = {edge - 1, 64, z}
    lamp = {edge, 64, z}

    set(ctx.owner, %{lever => state("lever", %{"face" => "floor", "facing" => "north"})})
    set({ctx.pb, ctx.eb}, %{lamp => BlockRegistry.default_state("redstone_lamp")})
    assert press(ctx.owner, lever) == :used
    assert props(lamp)["lit"] == "false"

    {:ok, [_]} = Region.hand_over(ctx.pb, ctx.pa)

    Valimc.TestWait.until(fn ->
      match?({pid, _, _} when pid == ctx.pa, Valimc.TestWorld.lookup(ctx.b))
    end)

    # One group: the lever's updates reach the lamp across the section line.
    assert press(ctx.owner, lever) == :used
    assert press(ctx.owner, lever) == :used
    assert props(lamp)["lit"] == "true"
  end
end
