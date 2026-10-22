defmodule Valimc.CookingOrbConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.Blocks.CookingAwards
  alias Valimc.Player.{GameMode, PlayerList}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.State, as: PlayerState

  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.Data.EntityTypes
  alias Valimc.Entity.ExperienceOrbs
  alias Valimc.World.Region
  alias Valimc.TestClient, as: Client

  # The orbs were spawned by the neighbouring region, whose durable handoff
  # delivers them here first (VMC-077h).
  test "native XP spawn/metadata and late tracking stay separate from item pickup" do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-orb-wire-#{nonce}")
    key = {98_000 + rem(nonce, 333) * 3, 2191}
    {rx, rz} = key
    source_key = {rx - 1, rz}
    pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}
    names = for i <- 1..2, do: "XP#{nonce}N#{i}"
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    File.mkdir_p!(base)

    on_exit(fn ->
      for p <- PlayerList.all(),
          p.name in names,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for owned_key <- [key, source_key],
          {pid, _} <- Valimc.TestWorld.registered(owned_key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    for name <- names do
      player =
        Map.merge(pose, %{
          game_mode: GameMode.new(:survival),
          abilities: Valimc.Player.Abilities.for_mode(:survival)
        })

      uuid = Valimc.Data.UUID.offline(name)
      {:ok, bytes} = PlayerState.encode(uuid, PlayerState.capture(player, %Inventory{}))
      path = Valimc.Player.Storage.path(base, uuid)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    {:ok, award} =
      CookingAwards.plan(
        %{
          "minecraft:gold_ingot_from_smelting_gold_ore" => 3,
          "minecraft:iron_ingot_from_smelting_raw_iron" => 5
        },
        %{"minecraft:iron_ingot_from_smelting_raw_iron" => 0}
      )

    orbs = ExperienceOrbs.award({pose.x + 4.0, 64.5, pose.z}, award)
    outgoing = %{destination: Valimc.TestWorld.section(key), records: orbs, merge: nil}

    Valimc.TestDisk.write(base, source_key, :items, %{
      records: [],
      ledger: %{sequence: 1, outgoing: outgoing, incoming: %{}}
    })

    {:ok, source_owner} = Valimc.TestWorld.item_owner(source_key)
    {:ok, {owner, epoch}} = Valimc.TestWorld.item_owner(key)
    wait(fn -> map_size(store({owner, epoch}).views) == 2 end)
    views = store({owner, epoch}).views
    uuids = MapSet.new(for {_, v} <- views, do: v.uuid)

    {_, client} = Client.login(hd(names))
    on_exit(fn -> Client.close(client) end)
    {client, spawns, values} = observe(client, uuids)
    assert Enum.sort(Map.values(values)) == [1, 3]
    assert MapSet.new(Map.keys(spawns)) == MapSet.new(Map.keys(views))
    Client.send_packet(client, :play, "player_loaded", <<>>)
    player = Enum.find(PlayerList.all(), &(&1.name == hd(names))).pid
    wait(fn -> Valimc.Player.Input.loaded?(Valimc.TestConn.state(player).player.input) end)
    # Only the two orbs are tracked; there are no items.
    assert map_size(Valimc.TestConn.state(player).entity_replication.tracked) == 2

    # Resting orbs need no movement packets (no more "predicted" resends).
    orb_id = spawns |> Map.keys() |> Enum.min()

    assert Valimc.TestWorld.visible_items(
             MapSet.new([key]),
             MapSet.new([Valimc.Data.Grid.chunk_key(pose.x, pose.z)])
           ) ==
             %{}

    # Out of reach until the client tracks it: vanilla sends the take only to
    # the item's trackers.
    {:ok, {_, ^epoch, item_id, 1}} =
      Region.create_item({owner, epoch}, ItemStack.new("stone", 3), {pose.x + 3.0, 64.1, pose.z})

    client = Client.await_spawn(client, item_id)
    client = Client.teleport(client, player, %{pose | x: pose.x + 3.0})
    {body, _client} = Client.await(client, :play, "take_item_entity")
    assert {^item_id, rest} = Wire.take_varint(body)
    {_collector, <<3>>} = Wire.take_varint(rest)

    wait(fn ->
      Enum.any?(Valimc.TestConn.state(player).inventory.slots, fn {_, s} ->
        s && s.item_id == Data.item("stone") && s.count == 3
      end)
    end)

    wait(fn -> store(source_owner).ledger.outgoing == nil end)
    installed = store({owner, epoch})
    assert Map.keys(installed.ledger.incoming) == [Valimc.TestWorld.section(source_key)]
    assert store(source_owner).views == %{}

    # One tracker for every kind: the two orbs, and the picked-up stone until the
    # next 50 ms tick reconciles its removal.
    tracked = Valimc.TestConn.state(player).entity_replication.tracked
    assert Map.has_key?(tracked, orb_id) and map_size(Map.delete(tracked, item_id)) == 2

    {_, late} = Client.login(List.last(names))
    on_exit(fn -> Client.close(late) end)
    {_late, late_spawns, _values} = observe(late, uuids)
    assert late_spawns == spawns
  end

  defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

  defp observe(client, uuids, chunks \\ 0, spawns \\ %{}, values \\ %{}) do
    if chunks >= 9 and map_size(spawns) == 2 and map_size(values) == 2 do
      {client, spawns, values}
    else
      {id, body, client} = Client.read(client)
      name = Data.name(:play, :clientbound, id)
      client = Client.auto_reply(client, :play, name, body)

      {spawns, values} =
        case name do
          "add_entity" ->
            {entity, <<uuid::binary-size(16), rest::binary>>} = Wire.take_varint(body)

            if MapSet.member?(uuids, uuid) do
              {type, <<x::float-64, y::float-64, z::float-64, _::binary>>} =
                Wire.take_varint(rest)

              assert type == EntityTypes.id("experience_orb")
              {Map.put(spawns, entity, {uuid, {x, y, z}}), values}
            else
              {spawns, values}
            end

          "set_entity_data" ->
            {entity, rest} = Wire.take_varint(body)

            if Map.has_key?(spawns, entity) do
              # The experience value alone: orbs have gravity (VMC-077i).
              <<8, 1, rest::binary>> = rest
              {value, <<255>>} = Wire.take_varint(rest)
              {spawns, Map.put(values, entity, value)}
            else
              {spawns, values}
            end

          _ ->
            {spawns, values}
        end

      observe(
        client,
        uuids,
        chunks + if(name == "level_chunk_with_light", do: 1, else: 0),
        spawns,
        values
      )
    end
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)
end
