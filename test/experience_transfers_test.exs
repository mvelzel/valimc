defmodule Valimc.ExperienceTransfersTest do
  use ExUnit.Case, async: false

  alias Valimc.{
    Connection,
    GameMode,
    Inventory,
    PlayerContainerTransfers,
    PlayerExperience,
    PlayerProgression,
    PlayerSnapshot,
    PlayerStore,
    World
  }

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbs,
    CookingOrbConsumptions,
    ExperienceTransfers,
    PendingCookingAwards,
    Region,
    Store
  }

  setup do
    nonce = System.unique_integer([:positive])
    key = {112_000 + rem(nonce, 1000), 2340}
    {x, z} = key
    at = {x * 128 + 8.5, 64.0, z * 128 + 8.5}
    base = Path.join(System.tmp_dir!(), "valimc-xp-pickup-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    File.mkdir_p!(base)
    uuid = Connection.offline_uuid("XpPickup#{nonce}")

    on_exit(fn ->
      for {registry, supervisor, k} <- [
            {Valimc.RegionRegistry, Valimc.RegionSupervisor, key},
            {Valimc.RegionStoreRegistry, Valimc.RegionStoreSupervisor, key},
            {Valimc.PlayerStoreRegistry, Valimc.PlayerStoreSupervisor, uuid}
          ],
          {pid, _} <- Registry.lookup(registry, k),
          do: DynamicSupervisor.terminate_child(supervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    {:ok, award} =
      Valimc.CookingAwards.plan(%{"minecraft:gold_ingot_from_smelting_gold_ore" => 6}, %{})

    source = <<71::128>>
    digest = :crypto.hash(:sha256, "original cooking decision")
    {:ok, pending, id} = PendingCookingAwards.put(%{}, key, source, 1, digest, at, award)

    cs = %Containers{
      pending_awards: pending,
      receipts: %{
        source => %{sequence: 1, digest: ContainerTransfers.result_digest(digest, :applied)}
      }
    }

    {:ok, cs, :materialized} = CookingOrbs.materialize(cs, key, id)
    [{orb, record}] = Map.to_list(cs.cooking_orbs[id])
    {:ok, bytes} = Containers.encode(key, cs)
    File.write!(Store.container_path(base, key), bytes)
    {:ok, owner} = World.item_owner(key)

    player = %{
      x: elem(at, 0),
      y: 64.0,
      z: elem(at, 2),
      yaw: 0.0,
      pitch: 0.0,
      game_mode: GameMode.new(:survival),
      abilities: Valimc.PlayerAbilities.for_mode(:survival),
      health: %Valimc.PlayerHealth{},
      food: %Valimc.PlayerFood{},
      motion: %Valimc.PlayerMotion{},
      environment: %Valimc.PlayerEnvironment{},
      last_death: nil,
      air_supply: 300,
      progression: %PlayerProgression{}
    }

    snapshot =
      PlayerSnapshot.capture(player, %Inventory{})
      |> Map.merge(%{transfer_sequence: 0, outbox: nil})

    request = %{
      kind: :experience,
      position: {floor(elem(at, 0)), 64, floor(elem(at, 2))},
      permit: <<0::128>>,
      orb_uuid: orb,
      value: record.value,
      consumed: 0,
      before: %PlayerExperience{},
      collector: 17
    }

    %{
      uuid: uuid,
      key: key,
      base: base,
      owner: owner,
      cs: cs,
      orb: orb,
      record: record,
      snapshot: snapshot,
      request: request,
      at: at
    }
  end

  defp prepare(ctx, snapshot, request) do
    {:ok, proposed} =
      PlayerContainerTransfers.prepare(ctx.uuid, snapshot.transfer_sequence, snapshot, %{
        kind: :container,
        key: ctx.key,
        request: request
      })

    {:ok, body} = Valimc.Physics.PlayerPose.geometry(:standing, ctx.at)

    actor = %{
      uuid: ctx.uuid,
      box: body.box,
      entity_id: 17,
      game_mode: GameMode.new(:survival),
      health: %{value: 20.0},
      expires: System.monotonic_time(:millisecond) + 1000
    }

    {:ok, request} = Region.admit_container_transfer(ctx.owner, proposed.outbox.request, actor)

    {:ok, prepared} =
      PlayerContainerTransfers.prepare(ctx.uuid, snapshot.transfer_sequence, snapshot, %{
        kind: :container,
        key: ctx.key,
        request: request
      })

    {prepared, request}
  end

  defp resource({pid, _}), do: :sys.get_state(pid).resource
  defp wait(f, n \\ 100)
  defp wait(f, 0), do: assert(f.())

  defp wait(f, n) do
    unless f.() do
      Process.sleep(20)
      wait(f, n - 1)
    end
  end

  test "native connection contact collects merged units and sends the persisted XP bar on reconnect",
       ctx do
    name = "XpPickup" <> Integer.to_string(System.unique_integer([:positive]))
    uuid = Connection.offline_uuid(name)
    {:ok, bytes} = PlayerSnapshot.encode(uuid, ctx.snapshot)
    path = PlayerStore.path(ctx.base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    {_, client} = Valimc.TestClient.login(name)
    assert client.experience.total == 0
    client = Valimc.TestClient.load_world(client)

    on_exit(fn ->
      Valimc.TestClient.close(client)

      for p <- Valimc.Players.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)
    end)

    Valimc.TestClient.send_packet(client, :play, "player_loaded", <<>>)
    player = Enum.find(Valimc.Players.all(), &(&1.name == name)).pid
    wait(fn -> :sys.get_state(player).player.progression.experience.total == 6 end, 300)
    assert resource(ctx.owner).containers.orb_consumption.counts[ctx.orb] == 2
    assert resource(ctx.owner).containers.receipts[uuid].sequence == 2
    assert :sys.get_state(player).inventory.slots == %{}
    {_, client} = Valimc.TestClient.await(client, :play, "take_item_entity")
    Valimc.TestClient.close(client)
    wait(fn -> Enum.all?(Valimc.Players.all(), &(&1.name != name)) end)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, uuid) == [] end)
    {:ok, disk} = PlayerSnapshot.decode(File.read!(path), uuid)
    assert disk.progression.experience.total == 6 and disk.outbox == nil
    Process.exit(elem(ctx.owner, 0), :kill)
    wait(fn -> not Process.alive?(elem(ctx.owner, 0)) end)
    {_, fresh} = Valimc.TestClient.login(name)
    on_exit(fn -> Valimc.TestClient.close(fresh) end)
    assert fresh.experience == Map.from_struct(disk.progression.experience)
  end

  test "XP capacity and pending Mending repairs refuse before any withdrawal", ctx do
    snapshot = ctx.snapshot
    too_full = put_in(snapshot.progression.experience.total, 2_147_483_647)
    request = %{ctx.request | before: too_full.progression.experience}

    assert {:error, _} =
             PlayerContainerTransfers.prepare(ctx.uuid, 0, too_full, %{
               kind: :container,
               key: ctx.key,
               request: request
             })

    tool = Valimc.Protocol.ItemStack.new("diamond_pickaxe")

    tool = %{
      tool
      | components: %{
          "minecraft:damage" => 12,
          "minecraft:enchantments" => %{"minecraft:mending" => 1}
        }
    }

    mending = put_in(snapshot.inventory.slots, %{36 => tool})

    assert {:error, _} =
             PlayerContainerTransfers.prepare(ctx.uuid, 0, mending, %{
               kind: :container,
               key: ctx.key,
               request: ctx.request
             })

    assert resource(ctx.owner).containers.orb_consumption == CookingOrbConsumptions.new()
  end

  test "one merged unit is consumed durably before a matching player grant; replay never grants again",
       ctx do
    {prepared, request} = prepare(ctx, ctx.snapshot, ctx.request)
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, prepared)
    assert {:ok, ^prepared} = PlayerSnapshot.decode(bytes, ctx.uuid)
    assert prepared.progression.experience.total == 0
    assert {:ok, :applied} = Region.container_transfer(ctx.owner, request)
    assert resource(ctx.owner).containers.orb_consumption.counts[ctx.orb] == 1
    {:ok, {_, receipt}} = Region.container_transfer_receipt(ctx.owner, ctx.uuid)
    assert {:ok, granted} = PlayerContainerTransfers.resolve(ctx.uuid, prepared, receipt)
    assert granted.progression.experience.total == 3 and granted.outbox == nil
    assert {:ok, :already_applied} = Region.container_transfer(ctx.owner, request)
    assert {:error, _} = PlayerContainerTransfers.resolve(ctx.uuid, granted, receipt)

    assert {:error, _} =
             PlayerContainerTransfers.resolve(ctx.uuid, prepared, %{receipt | digest: <<0::256>>})

    wait(fn ->
      Enum.any?(resource(ctx.owner).cooking_orbs.views, fn {_, v} ->
        v.uuid == ctx.orb and v.count == 1 and v.consumed == 1
      end)
    end)

    {second, request2} =
      prepare(ctx, granted, %{ctx.request | consumed: 1, before: granted.progression.experience})

    assert {:ok, :applied} = Region.container_transfer(ctx.owner, request2)
    {:ok, {_, receipt2}} = Region.container_transfer_receipt(ctx.owner, ctx.uuid)
    {:ok, done} = PlayerContainerTransfers.resolve(ctx.uuid, second, receipt2)
    assert done.progression.experience.total == 6
    wait(fn -> resource(ctx.owner).cooking_orbs.views == %{} end)

    assert World.visible_orbs(
             MapSet.new([ctx.key]),
             MapSet.new([World.chunk_key(elem(ctx.at, 0), elem(ctx.at, 2))])
           ) == %{}

    Process.exit(elem(ctx.owner, 0), :kill)
    wait(fn -> not Process.alive?(elem(ctx.owner, 0)) end)
    {:ok, recovered} = World.item_owner(ctx.key)
    assert resource(recovered).containers.orb_consumption.counts[ctx.orb] == 2
    assert resource(recovered).containers.cooking_orbs == ctx.cs.cooking_orbs
    {:ok, disk} = Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)
    assert disk.orb_consumption.counts[ctx.orb] == 2
  end

  test "unknown or over-consumed bodies fail validation, and rejection leaves XP and creation intact",
       ctx do
    assert {:error, _} =
             CookingOrbConsumptions.encode(%{revision: 3, counts: %{ctx.orb => 3}}, ctx.cs)

    assert {:error, _} =
             CookingOrbConsumptions.encode(%{revision: 1, counts: %{<<0::128>> => 1}}, ctx.cs)

    assert {:error, _} =
             CookingOrbConsumptions.encode(%{revision: 2, counts: %{ctx.orb => 1}}, ctx.cs)

    {prepared, request} = prepare(ctx, ctx.snapshot, ctx.request)
    # Owner replacement removes the short-lived permit. Recovery records a rejection.
    Process.exit(elem(ctx.owner, 0), :kill)
    wait(fn -> not Process.alive?(elem(ctx.owner, 0)) end)
    {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :rejected} = Region.recover_container_transfer(owner, request)
    {:ok, {_, receipt}} = Region.container_transfer_receipt(owner, ctx.uuid)
    {:ok, restored} = PlayerContainerTransfers.resolve(ctx.uuid, prepared, receipt)
    assert restored.progression == ctx.snapshot.progression
    assert resource(owner).containers.orb_consumption == CookingOrbConsumptions.new()
    assert resource(owner).containers.cooking_orbs == ctx.cs.cooking_orbs
    request2 = %{request | sequence: request.sequence + 1}

    assert {:ok, decision} =
             ExperienceTransfers.plan(resource(owner).containers, ctx.key, request2, false)

    assert decision.result == :rejected
  end

  test "player writer loss after region withdrawal recovers its original pending journal and grants once",
       ctx do
    {prepared, request} = prepare(ctx, ctx.snapshot, ctx.request)
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
    ref = make_ref()
    PlayerStore.prepare_container(writer, fence, ctx.snapshot, prepared.outbox, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _fence, saved}}, 2000
    assert saved.outbox == prepared.outbox
    assert {:ok, :applied} = Region.container_transfer(ctx.owner, request)
    Process.exit(writer, :kill)
    wait(fn -> not Process.alive?(writer) end)
    {:ok, writer, loaded, fence} = PlayerStore.open(ctx.uuid)
    assert loaded.progression.experience.total == 0 and loaded.outbox == prepared.outbox
    stale_fence = fence
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _fence, done}}, 2000
    assert done.progression.experience.total == 3 and done.outbox == nil
    # A disconnect can arrive before the socket processes the completion ACK.
    # Its stale progression must not overwrite the writer's committed grant.
    assert :ok = PlayerStore.close_session(writer, stale_fence, loaded)

    {:ok, disk} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert disk.progression.experience.total == 3 and disk.outbox == nil
  end
end
