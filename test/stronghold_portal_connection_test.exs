defmodule Valimc.StrongholdPortalConnectionTest do
  # A generated stronghold's portal room (VMC-026): its frames with the eyes
  # vanilla draws, filled by a player with eyes of ender, open the end portal,
  # which leads to the End.
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag timeout: 600_000
  alias Valimc.{
    Connection,
    Dimension,
    Inventory,
    PlayerHealth,
    PlayerSnapshot,
    PlayerStore,
    Players
  }

  alias Valimc.Portal.EndPortal
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  @seed 20_261_020
  # The nearest stronghold's portal room at this seed (`shpr`, box x 1169..1179,
  # y -7..0, z -722..-707): its frames ring the 3 × 3 at (1173..1175, -4, -713..-711).
  @room for x <- 1170..1178, y <- -5..-3, z <- -716..-708, do: {x, y, z}
  @interior for x <- 1173..1175, z <- -713..-711, do: {x, -4, z}

  setup_all do
    for level <- 0..4, do: Valimc.Commands.graph_payload(level)
    :ok
  end

  setup do
    nonce = System.unique_integer([:positive])
    name = "Strong#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-stronghold-#{nonce}")
    old = Valimc.config(:world_path)
    File.mkdir_p!(base)

    dimension = fn settings, biome_source, type ->
      %{
        "generator" => %{
          "biome_source" => biome_source,
          "settings" => settings,
          "type" => "minecraft:noise"
        },
        "type" => type
      }
    end

    File.write!(
      Valimc.World.Spawn.path(base),
      JSON.encode!(%{
        "spawn" => [0, 78, 0],
        "yaw" => 0.0,
        "generator" => %{
          "type" => "vanilla",
          "seed" => @seed,
          "features" => true,
          "settings" => %{
            "bonus_chest" => false,
            "generate_structures" => true,
            "seed" => @seed,
            "dimensions" => %{
              "minecraft:overworld" =>
                dimension.(
                  "minecraft:overworld",
                  %{"preset" => "minecraft:overworld", "type" => "minecraft:multi_noise"},
                  "minecraft:overworld"
                ),
              "minecraft:the_nether" =>
                dimension.(
                  "minecraft:nether",
                  %{"preset" => "minecraft:nether", "type" => "minecraft:multi_noise"},
                  "minecraft:the_nether"
                ),
              "minecraft:the_end" =>
                dimension.("minecraft:end", %{"type" => "minecraft:the_end"}, "minecraft:the_end")
            }
          }
        }
      })
    )

    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      for p <- Players.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for key <- Valimc.TestScope.neighborhood({9, -6}, 3),
          registry <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry, Valimc.ProtoRegistry],
          {pid, _} <- Registry.lookup(registry, key),
          do: Valimc.TestScope.kill(pid)

      elsewhere = [{{{:"$1", :_}, :"$2", :_}, [{:is_atom, :"$1"}], [:"$2"]}]

      for registry <- [Valimc.RegionRegistry, Valimc.ProtoRegistry],
          pid <- Registry.select(registry, elsewhere),
          do: Valimc.TestScope.kill(pid)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{name: name, uuid: uuid, path: PlayerStore.path(base, uuid)}
  end

  defp state(pid), do: Valimc.TestConn.state(pid)
  defp wait(fun), do: Valimc.TestWait.until(fun)

  defp blocks(positions, dimension \\ :overworld) do
    Dimension.within(dimension, fn ->
      read = Valimc.Portal.Access.reader()
      Map.new(positions, &{&1, read.(&1)})
    end)
  end

  test "a generated portal room's frames, filled with eyes of ender, open the portal to the End",
       ctx do
    # A flying creative player above the portal, holding eyes of ender.
    player = %{
      x: 1174.5,
      y: -2.5,
      z: -712.5,
      yaw: 0.0,
      pitch: 90.0,
      game_mode: Valimc.GameMode.new(:creative),
      abilities: %{Valimc.PlayerAbilities.for_mode(:creative) | flying: true},
      motion: %Valimc.PlayerMotion{},
      environment: %Valimc.PlayerEnvironment{},
      health: %PlayerHealth{},
      last_death: nil,
      air_supply: 300
    }

    inventory = %Inventory{slots: %{36 => ItemStack.new("ender_eye", 16)}}
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)

    # The room as generated: twelve frames, some with the eyes vanilla draws.
    frames = for {pos, s} <- blocks(@room), EndPortal.frame?(s), into: %{}, do: {pos, s}
    assert map_size(frames) == 12
    empty = for {pos, s} <- frames, not EndPortal.eye?(s), do: pos
    assert length(empty) in 1..11
    assert Enum.all?(blocks(@interior), fn {_, s} -> not EndPortal.frame?(s) end)

    {_, client} = Client.login(ctx.name)
    pid = wait(fn -> Enum.find(Players.all(), &(&1.name == ctx.name)) end).pid
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> not state(pid).teleport_pending end)
    on_exit(fn -> Client.close(client) end)

    # An eye into each empty frame, on its top face.
    empty
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.each(fn {pos, sequence} ->
      Client.send_packet(client, :play, "use_item_on", [
        Wire.varint(0),
        Wire.position(pos),
        <<1, 0.5::float-32, 1.0::float-32, 0.5::float-32, 0, 0>>,
        Wire.varint(sequence)
      ])

      wait(fn -> EndPortal.eye?(blocks([pos])[pos]) end)
    end)

    portal = Valimc.Registry.Blocks.default_state("end_portal")
    wait(fn -> Enum.all?(blocks(@interior), fn {_, s} -> s == portal end) end)
    assert state(pid).inventory.slots[36] == ItemStack.new("ender_eye", 16)

    # Into the portal: the End's arrival platform.
    deadline = System.monotonic_time(:millisecond) + 2000
    pose = %{x: 1174.5, y: -4.0, z: -711.5, yaw: 0.0, pitch: 0.0}
    :ok = GenServer.call(pid, {:teleport, pose, deadline})
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    {respawn, client} = Client.await(client, :play, "respawn", 3000)
    {_type, rest} = Wire.take_varint(respawn)
    {"minecraft:the_end", _} = Wire.take_string(rest)
    {position, client} = Client.await(client, :play, "player_position")
    {_, <<x::float-64, y::float-64, z::float-64, _::binary>>} = Wire.take_varint(position)
    _client = Client.auto_reply(client, :play, "player_position", position)
    assert {x, y, z} == {100.5, 49.0, 0.5}
    wait(fn -> state(pid).player.dimension == :the_end end)
  end
end
