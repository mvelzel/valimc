defmodule Valimc.ExperienceTransfersTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Freezing, Health}
  # Serial: a socket login reads the player's file from the global world path.
  @moduletag :tcp

  alias Valimc.{
    Connection,
    GameMode,
    Inventory,
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
    PendingCookingAwards
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
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
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
      living: %Valimc.Living{health: %Health{}, freezing: %Freezing{}, air_supply: 300},
      x: elem(at, 0),
      y: 64.0,
      z: elem(at, 2),
      yaw: 0.0,
      pitch: 0.0,
      game_mode: GameMode.new(:survival),
      abilities: Valimc.PlayerAbilities.for_mode(:survival),
      food: %Valimc.PlayerFood{},
      motion: %Valimc.PlayerMotion{},
      last_death: nil,
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

  defp resource({pid, _}), do: Valimc.TestConn.state(pid).resource
  defp wait(f, _budget \\ nil), do: Valimc.TestWait.until(f)

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
