defmodule Valimc.BrewingRegionTest do
  @moduledoc """
  A brewing stand in its owner (VMC-034o): it brews with the furnaces'
  worker ticks, shows its bottles on the block, keeps its times across a
  restart, spills when broken and takes clicks and hoppers by vanilla's rules.
  """
  use ExUnit.Case, async: true
  alias Valimc.Blocks.{Brewing, BrewingStand, ItemTransfer}
  alias Valimc.Data.PotionTypes
  alias Valimc.Protocol.{ItemStack, PotionContents}
  alias Valimc.TestScope
  alias Valimc.World.{ContainerClicks, Containers, RegionData}

  setup do
    nonce = System.unique_integer([:positive])
    key = {93_000 + rem(nonce, 3_333) * 3, 1995}
    {rx, rz} = key
    position = {rx * 128 + 40, 64, rz * 128 + 40}
    base = Path.join(System.tmp_dir!(), "valimc-brewing-#{nonce}")
    TestScope.isolate(key, world_path: base, cooking_simulation: true)
    File.mkdir_p!(base)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    %{key: key, base: base, position: position}
  end

  defp potion(item, name) do
    %ItemStack{
      item_id: Valimc.Protocol.ItemTypes.id(item),
      components: %{
        "minecraft:potion_contents" => %{PotionContents.empty() | potion: PotionTypes.id(name)}
      }
    }
  end

  defp seed(ctx, brewing) do
    {:ok, containers, entry} =
      Containers.create_owned(%Containers{}, ctx.key, ctx.position, :brewing_stand)

    {:ok, containers, _} =
      Containers.replace_brewing(containers, ctx.position, entry.revision, brewing)

    {:ok, bytes} = Containers.encode(ctx.key, containers)
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
    stand = Valimc.Data.Blocks.default_state("brewing_stand")
    Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, %{ctx.position => stand})
    state = RegionData.load(:overworld, ctx.key)
    chunk = Valimc.Data.Grid.chunk_key(elem(ctx.position, 0), elem(ctx.position, 2))
    {:noreply, state} = RegionData.handle_info({:ticket, self(), :forced, [chunk]}, state)
    state
  end

  defp tick(state) do
    state = RegionData.cooking_tick(state, System.monotonic_time(:millisecond))

    case Valimc.World.Jobs.get(state.jobs, :cooking) do
      %{token: token} ->
        epoch = state.epoch
        assert_receive {:resource, ^epoch, {:job, :cooking, ^token, _} = message}
        {:noreply, next} = RegionData.handle_info(message, state)
        next

      nil ->
        state
    end
  end

  test "water bottles brew into awkward potions in 400 ticks, shown on the block and kept", ctx do
    water = potion("potion", "water")

    brewing = %Brewing{
      slots: {water, water, nil, ItemStack.new("nether_wart", 2), ItemStack.new("blaze_powder")}
    }

    state = Enum.reduce(1..401, seed(ctx, brewing), fn _, state -> tick(state) end)
    {:ok, %{brewing: done}} = Containers.observe(state.containers, ctx.position)

    awkward = PotionTypes.id("awkward")

    assert {%{components: %{"minecraft:potion_contents" => %{potion: ^awkward}}}, _, nil, wart,
            nil} =
             done.slots

    assert wart.count == 1 and done.fuel == 19 and done.brew_time == 0
    block = Valimc.World.Blocks.get(state.blocks, ctx.position)
    assert block == BrewingStand.with_bottles(block, [true, true, false])
    assert Valimc.Data.Blocks.properties(block) |> Map.new() |> Map.get("has_bottle_1") == "true"

    # The times survive a restart.
    RegionData.terminate(:shutdown, state)
    reloaded = RegionData.load(:overworld, ctx.key)
    assert {:ok, %{brewing: ^done}} = Containers.observe(reloaded.containers, ctx.position)
    RegionData.terminate(:shutdown, reloaded)
  end

  test "the menu takes bottles one at a time and routes shift-clicks; hoppers use the faces" do
    entry = %{kind: :brewing_stand, revision: 1, brewing: %Brewing{}}
    view = ContainerClicks.view(entry)
    water = %{potion("potion", "water") | count: 1}
    powder = ItemStack.new("blaze_powder", 3)

    inventory = %Valimc.Menus.Inventory{slots: %{9 => powder, 10 => water}}

    # Shift-click blaze powder: the fuel slot (window 5 is inventory 9).
    {:ok, slots, inventory, []} = ContainerClicks.plan(view, inventory, :quick_move, 5, 0)
    assert elem(slots, 4).count == 3 and inventory.slots[9] == nil

    # Shift-click a water bottle: the first bottle slot.
    {:ok, slots, _inventory, []} =
      ContainerClicks.plan(%{view | slots: slots}, inventory, :quick_move, 6, 0)

    assert elem(slots, 0) == water

    # Hoppers: the ingredient from above, fuel and bottles from the sides,
    # and the ingredient leaves only as an empty bottle.
    stand = %{entry | brewing: %Brewing{slots: slots}}
    assert ItemTransfer.slots_for(stand, :up) == [3]
    refute ItemTransfer.can_place?(stand, 0, water, :north)
    assert ItemTransfer.can_place?(stand, 1, water, :north)
    refute ItemTransfer.can_take?(stand, 3, ItemStack.new("nether_wart"), :down)
    assert ItemTransfer.can_take?(stand, 3, ItemStack.new("glass_bottle"), :down)
  end
end
