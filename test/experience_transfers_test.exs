defmodule Valimc.ExperienceTransfersTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Freezing, Health}
  # Serial: a socket login reads the player's file from the global world path.
  @moduletag :tcp

  alias Valimc.{Connection, GameMode, Inventory, PlayerProgression}
  alias Valimc.Player.State, as: PlayerState

  alias Valimc.World.{Entities, ExperienceOrbs}

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
      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: Valimc.TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, award} =
      Valimc.CookingAwards.plan(%{"minecraft:gold_ingot_from_smelting_gold_ore" => 6}, %{})

    # Six XP from one recipe: one orb entity of value 3, count 2.
    [%{uuid: orb, value: 3, count: 2} = record] = ExperienceOrbs.award(at, award)
    Valimc.TestDisk.write(base, key, :items, %{records: [record]})
    {:ok, owner} = Valimc.TestWorld.item_owner(key)

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

    snapshot = PlayerState.capture(player, %Inventory{})

    %{
      uuid: uuid,
      key: key,
      base: base,
      owner: owner,
      orb: orb,
      record: record,
      snapshot: snapshot,
      at: at
    }
  end

  defp resource(owner), do: Valimc.TestRegion.section(owner)
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
    {:ok, bytes} = PlayerState.encode(uuid, ctx.snapshot)
    path = Valimc.Player.Storage.path(ctx.base, uuid)
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
    end)

    Valimc.TestClient.send_packet(client, :play, "player_loaded", <<>>)
    player = Enum.find(Valimc.Players.all(), &(&1.name == name)).pid
    wait(fn -> Valimc.TestConn.state(player).player.progression.experience.total == 6 end, 300)
    assert Entities.find(resource(ctx.owner).entities.store, ctx.orb) == {:error, :missing_item}
    assert Valimc.TestConn.state(player).inventory.slots == %{}
    {_, client} = Valimc.TestClient.await(client, :play, "take_item_entity")
    Valimc.TestClient.close(client)
    wait(fn -> Enum.all?(Valimc.Players.all(), &(&1.name != name)) end)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, uuid) == [] end)
    {:ok, disk} = PlayerState.decode(File.read!(path), uuid)
    assert disk.progression.experience.total == 6
    Process.exit(elem(ctx.owner, 0), :kill)
    wait(fn -> not Process.alive?(elem(ctx.owner, 0)) end)
    {_, fresh} = Valimc.TestClient.login(name)
    on_exit(fn -> Valimc.TestClient.close(fresh) end)
    assert fresh.experience == Map.from_struct(disk.progression.experience)
  end
end
