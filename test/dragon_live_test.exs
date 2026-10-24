defmodule Valimc.DragonLiveTest do
  # The native fight has one fixed End origin; these scenarios own that arena.
  use ExUnit.Case, async: false
  alias Valimc.Data.{Blocks, Grid}
  alias Valimc.Entity.Store
  alias Valimc.World.{Region, RegionData, RegionStorage, View}

  setup :scope

  def scope(_) do
    keys = for x <- -1..1, z <- -1..1, do: {x, z}
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-dragon-live-#{nonce}")

    Valimc.TestScope.isolate(keys,
      world_path: base,
      region_ticks: :manual,
      region_commit_ms: 600_000,
      regionizer: false,
      item_simulation: true
    )

    on_exit(fn ->
      Valimc.TestScope.stop_players(base)

      for key <- keys,
          {pid, _} <- Valimc.TestWorld.registered({:the_end, key}),
          do: Valimc.TestScope.kill(pid)

      File.rm_rf!(base)
    end)

    stone = Blocks.default_state("end_stone")

    layers =
      for y <- Grid.min_y()..Grid.max_y(),
          into: <<>>,
          do: <<if(y in 0..63, do: stone, else: 0)::16>>

    {:ok, image} = Valimc.Native.column_layers_image(layers, 0)

    for key <- keys do
      images = Map.new(Valimc.World.RegionGeneration.chunks_of(key), &{&1, image})
      :ok = RegionStorage.import(base, :the_end, key, %{columns: images})
    end

    {:ok, {pid, epoch}} = Valimc.TestWorld.owner({:the_end, {0, 0}})

    owners =
      for key <- keys, into: %{} do
        {:ok, {other, e}} = Valimc.TestWorld.owner({:the_end, key})
        if other != pid, do: assert({:ok, [_]} = Region.hand_over(other, pid))
        {key, {pid, e}}
      end

    for {key, owner} <- owners, do: :ok = Valimc.TestScope.simulate(owner, key)
    %{pid: pid, origin: {pid, epoch}, owners: owners, keys: keys, base: base}
  end

  # Admit through the real owner callback with one disclosed audience row;
  # the owner then runs its regular tick, entity and shared-frame paths.
  defp admit(c) do
    :sys.replace_state(c.pid, fn group ->
      resource = %{group.sections[{0, 0}].resource | siblings: group.peers}
      players = [%{uuid: <<457::128>>, alive: true, x: 100.0, y: 65.0, z: 0.0}]
      resource = RegionData.dragon_arena_tick(resource, players)
      put_in(group.sections[{0, 0}].resource, resource)
    end)
  end

  defp section(c, key \\ {0, 0}), do: Valimc.TestRegion.section(c.owners[key])

  defp dragons(c) do
    for key <- c.keys,
        {id, %{body: %{type: "minecraft:ender_dragon"}} = entry} <-
          section(c, key).entities.store.entries,
        do: {key, id, entry}
  end

  test "admission waits for the loaded arena and retains one UUID through reload", c do
    Valimc.TestRegion.replace_section(c.origin, fn s ->
      put_in(s.generation.absent, MapSet.new([{0, 0}]))
    end)

    admit(c)
    assert dragons(c) == []

    Valimc.TestRegion.replace_section(c.origin, fn s ->
      put_in(s.generation.absent, MapSet.new())
    end)

    Valimc.TestRegion.replace_section(c.origin, fn s -> put_in(s.arena_view.scan, 20) end)
    admit(c)
    [{key, id, dragon}] = dragons(c)
    uuid = dragon.entity.uuid

    Valimc.TestRegion.replace_section(c.owners[key], fn s ->
      body = %{dragon.body | mob: %{dragon.body.mob | no_ai: true}}
      put_in(s.entities.store, Store.change_body(s.entities.store, id, body))
    end)

    assert section(c).arena.dragon == uuid and section(c).arena.initialized
    assert section(c).arena.podium == {0, 63, 0}
    {:ok, _} = Region.step(c.origin, 2)
    assert [{_, _, %{entity: %{uuid: ^uuid}}}] = dragons(c)
    :ok = Region.flush(c.pid)
    Valimc.TestScope.kill(c.pid)
    Valimc.TestWait.until(fn -> Valimc.TestWorld.lookup({:the_end, {0, 0}}) == nil end)
    {:ok, owner} = Valimc.TestWorld.owner({:the_end, {0, 0}})
    restored = Valimc.TestRegion.section(owner)
    assert restored.arena.dragon == uuid and restored.arena.podium == {0, 63, 0}
    assert {:ok, _} = Store.find(restored.entities.store, uuid)
  end

  test "a sibling dragon completes once with first XP, portal, dropped blocks, egg and gateway",
       c do
    admit(c)
    {:ok, _} = Region.step(c.origin, 1)
    [{key, id, dragon}] = dragons(c)
    uuid = dragon.entity.uuid
    wool = {1, 63, 0}
    {:ok, observed} = Region.observe_blocks(c.origin, [wool])

    {:ok, _} =
      Region.set_blocks(c.origin, observed.fence, %{wool => Blocks.default_state("white_wool")})

    Valimc.TestRegion.replace_section(c.owners[key], fn s ->
      {:ok, store} = Store.remove(s.entities.store, s.entities.store.epoch, id, dragon.revision)
      put_in(s.entities.store, store)
    end)

    body = dragon.body
    body = put_in(body.mob.living.health.value, 0.0)
    record = Store.body_record(body, uuid, {129.0, 80.0, 20.0})
    :ok = Region.drop_items(c.owners[{1, 0}], [record])
    {:ok, _} = Region.step(c.origin, 200)
    assert dragons(c) == []
    fight = section(c).arena
    assert fight.killed and fight.previous_kill and length(fight.gateways) == 19
    view = View.new(:the_end)
    assert View.block(view, wool) == Blocks.default_state("end_portal")
    assert View.block(view, {0, 67, 0}) == Blocks.default_state("dragon_egg")

    [{gateway, _}] =
      for key <- c.keys,
          {at, entry} <- section(c, key).block_entities.entries,
          entry.type ==
            Valimc.Blocks.BlockEntityTypes.type_id(Blocks.default_state("end_gateway")),
          do: {at, entry}

    assert View.block(view, gateway) == Blocks.default_state("end_gateway")

    xp =
      for key <- c.keys,
          {_, %{kind: :orb, value: v, count: n}} <- section(c, key).entities.store.entries,
          reduce: 0,
          do: (sum -> sum + v * n)

    assert xp == 12_000

    assert Enum.any?(
             for(
               key <- c.keys,
               {_, %{kind: :item, stack: stack}} <- section(c, key).entities.store.entries,
               do: stack
             ),
             &(&1.item_id == Valimc.Protocol.ItemTypes.id("minecraft:white_wool"))
           )

    :ok = Region.flush(c.pid)
    Valimc.TestScope.kill(c.pid)
    {:ok, owner} = Valimc.TestWorld.owner({:the_end, {0, 0}})
    assert Valimc.TestRegion.section(owner).arena == fight
    {:ok, _} = Region.step(owner, 3)
    assert Valimc.TestRegion.section(owner).arena.gateways == fight.gateways
  end
end

defmodule Valimc.DragonLiveConnectionTest do
  # Uses the one fixed End arena and the listening socket.
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag timeout: 120_000
  alias Valimc.Player.{Abilities, GameMode}
  alias Valimc.Protocol.BossPackets
  alias Valimc.TestClient, as: Client
  alias Valimc.TestPlayer
  alias Valimc.World.{Region, Dragon.Arena}

  setup {Valimc.DragonLiveTest, :scope}

  test "a spectator loads the arena and receives add, fresh health and removal packets", c do
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, c.base)
    on_exit(fn -> Application.put_env(:valimc, :world_path, old) end)
    name = "DragonBar#{System.unique_integer([:positive])}"
    uuid = Valimc.Data.UUID.offline(name)
    Valimc.TestScope.isolate(uuid, player_ticks: :manual)
    ctx = Map.merge(c, %{name: name, uuid: uuid, path: Valimc.Player.Storage.path(c.base, uuid)})

    player = %{
      x: 100.5,
      y: 65.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      dimension: :the_end,
      game_mode: GameMode.new(:spectator),
      abilities: Abilities.for_mode(:spectator),
      living: %Valimc.Living{health: %Valimc.Living.Health{value: 20.0}},
      motion: %Valimc.Player.Motion{},
      food: %Valimc.Player.Food{}
    }

    TestPlayer.save(ctx, player, %Valimc.Menus.Inventory{})
    {client, connection} = TestPlayer.login(ctx)
    assert TestPlayer.state(connection).player.dimension == :the_end

    simulated = fn ->
      TestPlayer.state(connection).wanted
      |> Map.values()
      |> Enum.reduce(MapSet.new(), fn {_, _, chunks}, all -> MapSet.union(all, chunks) end)
    end

    assert MapSet.subset?(MapSet.new(Arena.chunks()), simulated.())
    {:ok, _} = Region.step(c.origin, 1)
    {add, client} = Client.await(client, :play, "boss_event")
    <<bar::binary-size(16), 0, _::binary>> = add

    {_, expected} =
      BossPackets.add(bar, Valimc.Text.translatable("entity.minecraft.ender_dragon"), 1.0)

    assert add == IO.iodata_to_binary(expected)

    group = :sys.get_state(c.pid)
    dragon_uuid = group.sections[{0, 0}].resource.arena.dragon

    [{key, _id, entry}] =
      for {key, section} <- group.sections,
          {id, entry} <- section.resource.entities.store.entries,
          entry.entity.uuid == dragon_uuid,
          do: {key, id, entry}

    hit = %{
      source: Valimc.Living.DamageSource.new(:player_attack),
      amount: 100.0,
      dragon_part: 0,
      attacker: %{uuid: uuid, player: true, type: "minecraft:player", entity_id: 1, mainhand: nil},
      position: {entry.entity.x, entry.entity.y, entry.entity.z}
    }

    assert {:ok, %{hurt: true}} = Region.hurt_entity(c.owners[key], dragon_uuid, hit)

    {:ok, _} = Region.step(c.origin, 1)
    {progress, client} = Client.await(client, :play, "boss_event")
    assert progress == <<bar::binary, 2, 0.5::float-32>>

    # Same chunk, outside the vertical audience sphere: tickets must refresh
    # even though neither the view nor its chunk centre changed.
    Valimc.TestConn.replace(connection, fn s -> put_in(s.player.y, 400.0) end)
    TestPlayer.tick(connection)
    Valimc.TestWait.until(fn -> not MapSet.subset?(MapSet.new(Arena.chunks()), simulated.()) end)
    {:ok, _} = Region.step(c.origin, 20)
    {remove, _} = Client.await(client, :play, "boss_event")
    assert remove == <<bar::binary, 1>>
  end
end
