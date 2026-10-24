defmodule Valimc.EndCrystalTest do
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks
  alias Valimc.Entity.{Body, EndCrystal, Projectile, Store}
  alias Valimc.World.{Explosion, Region}

  test "a stored crystal restores its data and an arrow hits the live object" do
    nonce = System.unique_integer([:positive])
    key = {96_000 + rem(nonce, 3_333) * 3, 2100}
    base = Path.join(System.tmp_dir!(), "valimc-crystal-#{nonce}")
    Valimc.TestScope.isolate(key, world_path: base, region_ticks: :manual, item_simulation: true)

    on_exit(fn ->
      for dimension <- [:overworld, :the_end],
          {pid, _} <- Valimc.TestWorld.registered({dimension, key}),
          do: Valimc.TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, owner} = Valimc.TestWorld.owner(key)
    {sx, sz} = key
    {x, y, z} = at = {sx * 128 + 40, 80, sz * 128 + 40}
    {:ok, observed} = Region.observe_blocks(owner, [at])
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{at => Blocks.default_state("obsidian")})
    :ok = Region.place_crystal(owner, at, [])
    assert {:error, :crystal_occupied} = Region.place_crystal(owner, at, [])
    store = Valimc.TestRegion.section(owner).entities.store
    [{id, entry}] = Map.to_list(store.entries)
    assert entry.body.data.bottom == false

    {:ok, body} =
      Body.generated(EndCrystal.type(), "{beam_target:[I;0,128,0],ShowBottom:0b}", false)

    assert body.data.beam == {0, 128, 0} and body.data.bottom == false

    Valimc.TestRegion.replace_section(owner, fn s ->
      put_in(s.entities.store, Store.change_body(s.entities.store, id, body))
    end)

    :ok = Region.flush(elem(owner, 0))
    Valimc.TestScope.kill(elem(owner, 0))
    {:ok, owner} = Valimc.TestWorld.owner(key)
    store = Valimc.TestRegion.section(owner).entities.store
    {:ok, {_, id, _}} = Store.find(store, entry.entity.uuid)
    assert store.entries[id].body.data == body.data
    # Native generated spike records use a visible bottom plate.
    {:ok, generated} = Body.generated(EndCrystal.type(), nil, false)
    assert generated.data.bottom
    # An explosion removes a crystal, without adding a second explosion.
    actions =
      Explosion.hits(%Explosion{center: {x + 2.5, y + 1.0, z + 0.5}, radius: 4.0}, store.entries)

    assert [{^id, :destroy}] = actions
    assert Explosion.apply_hits(store, key, actions).entries == %{}
    # The owner exposes objects to the actual projectile collision path.
    :ok = Valimc.TestScope.simulate(owner, key)
    arrow = Projectile.new("minecraft:arrow", nil) |> Projectile.shoot({1.0, 0.0, 0.0}, 3.0, 0.0)

    # Both arrows saw the crystal; the second can reach an already removed
    # target while this tick's plans apply.
    :ok =
      Region.drop_items(
        owner,
        for(
          n <- [2, 3],
          do: Store.body_record(arrow, <<n::128>>, {x - 2.5, y + 1.5, z + 0.5})
        )
      )

    {:ok, _} = Region.step(owner, 3)

    assert {:error, :missing_item} =
             Store.find(Valimc.TestRegion.section(owner).entities.store, entry.entity.uuid)

    assert {:error, :missing_item} =
             Store.find(Valimc.TestRegion.section(owner).entities.store, <<2::128>>)

    chunk = Valimc.Data.Grid.chunk_key(x, z)
    {:ok, %{images: images}} = Region.column_images(owner, [chunk])
    :ok = Valimc.World.RegionStorage.import(base, :the_end, key, %{columns: images})
    {:ok, ending} = Valimc.TestWorld.owner({:the_end, key})
    {:ok, observed} = Region.observe_blocks(ending, [at])

    {:ok, _} =
      Region.set_blocks(ending, observed.fence, %{at => Blocks.default_state("obsidian")})

    :ok = Region.place_crystal(ending, at, [])
    :ok = Valimc.TestScope.simulate(ending, key)
    {:ok, _} = Region.step(ending, 1)
    {:ok, %{blocks: blocks}} = Region.observe_blocks(ending, [{x, y + 1, z}])
    assert blocks[{x, y + 1, z}] == Blocks.default_state("fire")
  end
end

defmodule Valimc.EndCrystalConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Data.Blocks
  alias Valimc.Entity.Store
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.TestPlayer
  alias Valimc.World.Region

  test "survival placement consumes once, an occupied base refuses, and melee explodes it" do
    ctx = TestPlayer.scope("Crystal", {160_000, 2101}, survival: {2, false})

    player =
      Map.merge(ctx.pose, %{
        game_mode: Valimc.Player.GameMode.new(:survival),
        abilities: Valimc.Player.Abilities.for_mode(:survival),
        living: %Valimc.Living{health: %Valimc.Living.Health{value: 20.0}},
        motion: %Valimc.Player.Motion{},
        food: %Valimc.Player.Food{}
      })

    TestPlayer.save(ctx, player, %Inventory{slots: %{36 => ItemStack.new("end_crystal", 2)}})
    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    at = {floor(ctx.pose.x) + 3, 64, floor(ctx.pose.z)}
    {:ok, seen} = Region.observe_blocks(owner, [at])
    {:ok, _} = Region.set_blocks(owner, seen.fence, %{at => Blocks.default_state("obsidian")})

    use = fn seq ->
      Client.send_packet(client, :play, "use_item_on", [
        Wire.varint(0),
        Wire.position(at),
        Wire.varint(1),
        <<0.5::float-32, 1.0::float-32, 0.5::float-32, 0, 0>>,
        Wire.varint(seq)
      ])
    end

    use.(1)
    {_, client} = Client.await(client, :play, "block_changed_ack")
    assert TestPlayer.state(pid).inventory.slots[36].count == 1
    use.(2)
    {_, client} = Client.await(client, :play, "block_changed_ack")
    assert TestPlayer.state(pid).inventory.slots[36].count == 1
    store = Valimc.TestRegion.section(owner).entities.store

    [{id, entry}] =
      Enum.filter(store.entries, fn {_, e} ->
        e[:body] && e.body.type == "minecraft:end_crystal"
      end)

    {_, client} = Client.await(client, :play, "add_entity")
    Client.send_packet(client, :play, "attack", Wire.varint(id))

    Valimc.TestWait.until(fn ->
      Store.find(Valimc.TestRegion.section(owner).entities.store, entry.entity.uuid) ==
        {:error, :missing_item}
    end)

    {_, _client} = Client.await(client, :play, "explode")
    # The nested player effect must leave the attacker's callback and output
    # context usable, including the survival item use it already committed.
    Client.send_packet(client, :play, "set_carried_item", <<1::16>>)
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.selected == 1 end)
    assert TestPlayer.state(pid).inventory.slots[36].count == 1
  end
end
