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

      # This serial suite owns the End; stop generation and final writes
      # before deleting its world, including a socket's extra view chunks.
      Valimc.TestScope.stop_dimensions()
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

  test "the group's natural spawner keeps its far dragon while removing an ordinary hostile", c do
    admit(c)
    [{_key, dragon_id, _dragon}] = dragons(c)
    {:ok, body} = Valimc.Entity.Body.new("minecraft:zombie")
    uuid = <<459::128>>
    :ok = Region.drop_items(c.origin, [Store.body_record(body, uuid, {0.5, 128.0, 0.5})])
    store = section(c).entities.store
    {:ok, {_, zombie_id, _}} = Store.find(store, uuid)
    resources = Map.new(:sys.get_state(c.pid).sections, fn {key, s} -> {key, s.resource} end)

    {_spawning, plan} =
      Valimc.World.Spawning.plan(%{
        sections: resources,
        stores: for({_, r} <- resources, do: r.blocks.ref),
        absent: [],
        players: [{180.5, 128.0, 0.5, false, true}],
        rest: [],
        spawning: Valimc.World.Spawning.new(),
        environment: Valimc.World.Spawning.environment(:the_end),
        dimension: :the_end,
        game_time: 1
      })

    discarded = for {_, {_, discards, _, _}} <- plan, id <- discards, do: id
    assert zombie_id in discarded
    refute dragon_id in discarded
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

  # The fixture starts at a defeated fight; crystals, block effects, jobs,
  # clock and restart all use the live owner paths. The disclosed audience
  # row is retained so the serial owner test needs no listening client.
  defp defeated(c) do
    admit(c)

    for {key, id, entry} <- dragons(c) do
      Valimc.TestRegion.replace_section(c.owners[key], fn state ->
        {:ok, store} =
          Store.remove(state.entities.store, state.entities.store.epoch, id, entry.revision)

        put_in(state.entities.store, store)
      end)
    end

    Valimc.TestRegion.replace_section(c.origin, fn state ->
      state = %{state | arena: %{state.arena | dragon: nil, killed: true, previous_kill: true}}
      state = put_in(state.arena_view.scan, -10_000)
      RegionData.apply_sibling(state, {:arena_effect, {:podium, true}})
    end)

    {:ok, _} = Region.step(c.origin, 1)
  end

  defp place_ritual(c) do
    for {x, z} <- [{0, -3}, {3, 0}, {0, 3}, {-3, 0}] do
      key = Grid.region_key(Grid.chunk_key(x, z))

      Valimc.TestWait.until(fn ->
        case Region.place_crystal(c.owners[key], {x, 63, z}, []) do
          :ok -> true
          {:error, {:retry, _}} -> false
          error -> flunk("crystal placement failed: #{inspect(error)}")
        end
      end)
    end

    assert section(c).arena.stage == :start
    section(c).arena.crystals
  end

  defp crystals(c) do
    for key <- c.keys,
        {_, %{body: %{type: "minecraft:end_crystal"}} = entry} <-
          section(c, key).entities.store.entries,
        do: entry
  end

  defp reopen(c) do
    Valimc.TestWait.until(fn ->
      Enum.all?(:sys.get_state(c.pid).sections, fn {_, section} ->
        not Valimc.World.Jobs.busy?(section.resource.jobs)
      end)
    end)

    :ok = Region.flush(c.pid)
    Valimc.TestScope.kill(c.pid)
    {:ok, {pid, epoch}} = Valimc.TestWorld.owner({:the_end, {0, 0}})

    owners =
      for key <- c.keys, into: %{} do
        {:ok, {other, e}} = Valimc.TestWorld.owner({:the_end, key})
        if other != pid, do: assert({:ok, [_]} = Region.hand_over(other, pid))
        {key, {pid, e}}
      end

    for {key, owner} <- owners, do: :ok = Valimc.TestScope.simulate(owner, key)
    %{c | pid: pid, origin: {pid, epoch}, owners: owners}
  end

  defp advance(c, ticks) do
    for _ <- 1..ticks do
      before = section(c).arena
      # A multi-tick step is one callback and cannot receive worker replies.
      # Count accepted ritual clock steps, letting existing jobs finish and
      # group fencing settle between callbacks, as live ticks do.
      Valimc.TestWait.until(fn ->
        ready =
          Enum.all?(:sys.get_state(c.pid).sections, fn {_, section} ->
            RegionData.write_busy(section.resource) == nil
          end)

        if ready do
          {:ok, _} = Region.step(c.origin, 1)
          after_step = section(c).arena

          before.stage == nil or
            {after_step.stage, after_step.time} != {before.stage, before.time}
        end
      end)
    end
  end

  defp ritual_clock(%{stage: :start}), do: 0
  defp ritual_clock(%{stage: :preparing, time: t}), do: 1 + t
  defp ritual_clock(%{stage: :pillars, time: t}), do: 102 + t
  defp ritual_clock(%{stage: :summoning, time: t}), do: 503 + t
  defp ritual_clock(%{stage: nil}), do: 604

  test "all ten live pillars and the next dragon resume across restart, then reward 500 XP", c do
    defeated(c)
    ritual = place_ritual(c)
    advance(c, 1)
    Valimc.TestWait.until(fn -> section(c).arena_pillars != nil end)
    advance(c, 141)
    assert section(c).arena.stage == :pillars and section(c).arena.time == 40
    [first] = Enum.reject(crystals(c), &(&1.entity.uuid in ritual))
    assert first.body.data.invulnerable and first.body.data.beam == {0, 128, 0}
    fight = section(c).arena
    c = reopen(c)
    assert section(c).arena == fight and section(c).arena_pillars == nil
    admit(c)
    Valimc.TestRegion.replace_section(c.origin, &put_in(&1.arena_view.scan, -10_000))
    Valimc.TestWait.until(fn -> section(c).arena_pillars != nil end)
    advance(c, 604 - ritual_clock(section(c).arena))
    fight = section(c).arena
    assert fight.stage == nil and not fight.killed and fight.previous_kill, inspect(fight)
    assert length(fight.gateways) == 20
    assert length(crystals(c)) == 10
    assert Enum.all?(crystals(c), &(not &1.body.data.invulnerable and &1.body.data.beam == nil))
    assert Enum.all?(crystals(c), &(&1.entity.uuid not in ritual))
    view = View.new(:the_end)

    for s <- section(c).arena_spikes do
      assert View.block(view, {s.x, s.height, s.z}) == Blocks.default_state("bedrock")
      assert View.block(view, {s.x, s.height - 1, s.z}) == Blocks.default_state("obsidian")
    end

    [{key, id, dragon}] = dragons(c)
    assert fight.dragon == dragon.entity.uuid

    Valimc.TestRegion.replace_section(c.owners[key], fn state ->
      body = dragon.body
      body = put_in(body.mob.living.health.value, 0.0)
      put_in(state.entities.store, Store.change_body(state.entities.store, id, body))
    end)

    # Existing item plans can defer an entity phase; bound wall ticks while
    # the native actor still retains exactly its own 200 death ticks.
    Enum.reduce_while(1..220, nil, fn _, _ ->
      if section(c).arena.killed do
        {:halt, nil}
      else
        advance(c, 1)
        {:cont, nil}
      end
    end)

    xp =
      for key <- c.keys,
          {_, %{kind: :orb, value: v, count: n}} <- section(c, key).entities.store.entries,
          reduce: 0,
          do: (sum -> sum + v * n)

    assert xp == 500
    assert dragons(c) == []
    assert section(c).arena.killed and length(section(c).arena.gateways) == 19
  end

  test "a sibling participant aborts and resets spike protection; missing restored participants abort",
       c do
    defeated(c)
    _ = place_ritual(c)
    advance(c, 1)
    Valimc.TestWait.until(fn -> section(c).arena_pillars != nil end)
    advance(c, 141)
    assert Enum.any?(crystals(c), & &1.body.data.invulnerable)
    participant = Enum.find(crystals(c), &(&1.entity.x < 0 and &1.entity.z > 0))

    hit = %{
      source: Valimc.Living.DamageSource.new(:player_attack),
      amount: 1.0,
      attacker: nil,
      position: {participant.entity.x, participant.entity.y, participant.entity.z}
    }

    assert {:ok, %{hurt: true}} =
             Region.hurt_entity(c.owners[{-1, 0}], participant.entity.uuid, hit)

    assert section(c).arena.stage == nil and section(c).arena.killed

    assert Enum.all?(
             Enum.reject(crystals(c), &(&1.entity.uuid in section(c).arena.crystals)),
             fn entry ->
               if Valimc.World.Dragon.Ritual.on_spike?(entry.entity, section(c).arena_spikes),
                 do: not entry.body.data.invulnerable and entry.body.data.beam == nil,
                 else: true
             end
           )

    assert View.block(View.new(:the_end), {1, 63, 0}) == Blocks.default_state("end_portal")

    Valimc.TestRegion.replace_section(c.origin, fn state ->
      %{state | arena: %{state.arena | stage: :summoning, time: 90, crystals: [<<999::128>>]}}
    end)

    c = reopen(c)
    admit(c)
    assert section(c).arena.stage == nil and section(c).arena.killed
    assert dragons(c) == []
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
    Client.close(client)
    # This fixture parks its normal commit timer for ten minutes. Flush
    # the leaving player's final frame explicitly before awaiting release.
    Valimc.TestWait.until(fn -> :sys.get_state(c.pid).players[uuid] == nil end)
    :ok = Region.flush(c.pid)
    Valimc.TestWait.until(fn -> Registry.lookup(Valimc.PlayerRegistry, uuid) == [] end)
  end
end
