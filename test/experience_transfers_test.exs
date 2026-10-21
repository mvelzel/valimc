defmodule Valimc.ExperienceTransfersTest do
  use ExUnit.Case, async: true

  alias Valimc.{
    GameMode,
    Inventory,
    PlayerContainerTransfers,
    PlayerExperience,
    PlayerProgression,
    PlayerSnapshot,
    World
  }

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbs,
    PendingCookingAwards,
    Region
  }

  setup :scope

  def scope(_context) do
    nonce = System.unique_integer([:positive])
    key = {112_000 + rem(nonce, 333) * 3, 2340}
    {x, z} = key
    at = {x * 128 + 8.5, 64.0, z * 128 + 8.5}
    base = Path.join(System.tmp_dir!(), "valimc-xp-pickup-#{nonce}")
    Valimc.TestScope.isolate(key, world_path: base)
    File.mkdir_p!(base)
    uuid = :crypto.strong_rand_bytes(16)

    on_exit(fn ->
      for registry <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(registry, key),
          do: Valimc.TestScope.kill(pid)

      File.rm_rf(base)
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
    Valimc.TestDisk.write(base, key, :containers, bytes)
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

  def resource({pid, _}), do: Valimc.TestConn.state(pid).resource
  def wait(f, _budget \\ nil), do: Valimc.TestWait.until(f)

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
    {:ok, disk} = Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)
    assert disk.orb_consumption.counts[ctx.orb] == 2
  end
end

defmodule Valimc.ExperienceTransfersTest.Serial do
  use ExUnit.Case, async: false
  # Serial: a socket login reads the player's file from the global world path.
  @moduletag :tcp
  import Valimc.ExperienceTransfersTest, only: [resource: 1, wait: 1, wait: 2]
  alias Valimc.{Connection, PlayerSnapshot, PlayerStore}

  setup {Valimc.ExperienceTransfersTest, :scope}

  setup ctx do
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, ctx.base)

    on_exit(fn ->
      Application.put_env(:valimc, :world_path, previous)
      Valimc.TestScope.stop_players(ctx.base)
    end)
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
end
