defmodule Valimc.CookingOrbConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.{
    Connection,
    CookingAwards,
    GameMode,
    Inventory,
    Players,
    PlayerSnapshot,
    PlayerStore,
    World
  }

  alias Valimc.Protocol.{Data, EntityTypes, ItemStack, Wire}
  alias Valimc.World.{Containers, ContainerTransfers, PendingCookingAwards, Region}
  alias Valimc.TestClient, as: Client

  for remote <- [false, true] do
    @tag remote: remote
    test "native XP spawn/metadata, late tracking and owner replacement stay separate from item pickup (remote=#{remote})",
         %{remote: remote} do
      nonce = System.unique_integer([:positive])
      base = Path.join(System.tmp_dir!(), "valimc-orb-wire-#{nonce}")
      key = {98_000 + rem(nonce, 333) * 3, 2191}
      {rx, rz} = key
      source_key = if remote, do: {rx - 1, rz}, else: key
      pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}
      names = for i <- 1..2, do: "XP#{nonce}N#{i}"
      previous = Valimc.config(:world_path)
      Application.put_env(:valimc, :world_path, base)
      File.mkdir_p!(base)

      on_exit(fn ->
        for p <- Players.all(),
            p.name in names,
            do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

        for name <- names,
            {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, Connection.offline_uuid(name)),
            do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

        for {registry, supervisor} <- [
              {Valimc.RegionRegistry, Valimc.RegionSupervisor},
              {Valimc.RegionStoreRegistry, Valimc.RegionStoreSupervisor}
            ],
            owned_key <- Enum.uniq([key, source_key]),
            {pid, _} <- Registry.lookup(registry, owned_key),
            do: DynamicSupervisor.terminate_child(supervisor, pid)

        Application.put_env(:valimc, :world_path, previous)
        File.rm_rf!(base)
      end)

      for name <- names do
        player =
          Map.merge(pose, %{
            game_mode: GameMode.new(:survival),
            abilities: Valimc.PlayerAbilities.for_mode(:survival)
          })

        uuid = Connection.offline_uuid(name)
        {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(player, %Inventory{}))
        path = PlayerStore.path(base, uuid)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
      end

      source = <<63::128>>
      digest = :crypto.hash(:sha256, "XP fixture")

      {:ok, award} =
        CookingAwards.plan(
          %{
            "minecraft:gold_ingot_from_smelting_gold_ore" => 3,
            "minecraft:iron_ingot_from_smelting_raw_iron" => 5
          },
          %{"minecraft:iron_ingot_from_smelting_raw_iron" => 0}
        )

      {:ok, pending, id} =
        PendingCookingAwards.put(
          %{},
          source_key,
          source,
          1,
          digest,
          {pose.x + 4.0, 64.5, pose.z},
          award
        )

      cs = %Containers{
        pending_awards: pending,
        receipts: %{
          source => %{sequence: 1, digest: ContainerTransfers.result_digest(digest, :applied)}
        }
      }

      {:ok, bytes} = Containers.encode(source_key, cs)
      Valimc.TestDisk.write(base, source_key, :containers, bytes)
      {:ok, {source_owner, _}} = World.item_owner(source_key)
      {:ok, {owner, epoch}} = World.item_owner(key)
      wait(fn -> map_size(:sys.get_state(owner).resource.cooking_orbs.views) == 2 end)
      views = :sys.get_state(owner).resource.cooking_orbs.views
      uuids = MapSet.new(for {_, v} <- views, do: v.uuid)

      {_, client} = Client.login(hd(names))
      on_exit(fn -> Client.close(client) end)
      {client, spawns, values} = observe(client, uuids)
      assert Enum.sort(Map.values(values)) == [1, 3]
      assert MapSet.new(Map.keys(spawns)) == MapSet.new(Map.keys(views))
      Client.send_packet(client, :play, "player_loaded", <<>>)
      player = Enum.find(Players.all(), &(&1.name == hd(names))).pid
      wait(fn -> Valimc.PlayerInput.loaded?(:sys.get_state(player).player.input) end)
      # Only the two orbs are tracked; there are no items.
      assert map_size(:sys.get_state(player).entity_replication.tracked) == 2

      {body, client} = Client.await(client, :play, "entity_position_sync")

      {orb_id, <<0, x::float-64, y::float-64, z::float-64, 0::float-32, 0::float-32, 0>>} =
        Wire.take_varint(body)

      assert {_, {^x, ^y, ^z}} = spawns[orb_id]
      {body, client} = Client.await(client, :play, "set_entity_motion")
      assert {^orb_id, <<0>>} = Wire.take_varint(body)

      assert World.visible_items(MapSet.new([key]), MapSet.new([World.chunk_key(pose.x, pose.z)])) ==
               %{}

      {:ok, {^owner, ^epoch, item_id, 1}} =
        Region.create_item({owner, epoch}, ItemStack.new("stone", 3), {pose.x, 64.1, pose.z})

      {body, client} = Client.await(client, :play, "take_item_entity")
      assert {^item_id, rest} = Wire.take_varint(body)
      {_collector, <<3>>} = Wire.take_varint(rest)

      wait(fn ->
        Enum.any?(:sys.get_state(player).inventory.slots, fn {_, s} ->
          s && s.item_id == Data.item("stone") && s.count == 3
        end)
      end)

      installed = :sys.get_state(owner).resource.containers
      source_installed = :sys.get_state(source_owner).resource.containers
      assert source_installed.pending_awards == pending

      if remote do
        wait(fn ->
          :sys.get_state(source_owner).resource.containers.orb_transfers.outgoing[id] ==
            :delivered
        end)

        assert installed.pending_awards == %{} and map_size(installed.orb_transfers.incoming) == 1
        assert :sys.get_state(source_owner).resource.cooking_orbs.views == %{}
      else
        assert map_size(installed.cooking_orbs[id]) == 2
      end

      # One tracker for every kind: the two orbs, and the picked-up stone until the
      # next 50 ms tick reconciles its removal.
      tracked = :sys.get_state(player).entity_replication.tracked
      assert Map.has_key?(tracked, orb_id) and map_size(Map.delete(tracked, item_id)) == 2

      {_, late} = Client.login(List.last(names))
      on_exit(fn -> Client.close(late) end)
      {_late, late_spawns, _values} = observe(late, uuids)
      assert late_spawns == spawns
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      wait(fn ->
        case World.item_owner(key) do
          {:ok, {pid, _}} -> pid != owner
          _ -> false
        end
      end)

      client = removed(client, MapSet.new(Map.keys(spawns)))
      {_client, recreated, new_values} = observe(client, uuids, 9)
      assert Enum.sort(Map.values(new_values)) == [1, 3]
      assert MapSet.disjoint?(MapSet.new(Map.keys(spawns)), MapSet.new(Map.keys(recreated)))
      {:ok, {replacement, new_epoch}} = World.item_owner(key)
      assert new_epoch != epoch
      assert :sys.get_state(replacement).resource.containers == installed
    end
  end

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
              <<5, 8, 1, 8, 1, rest::binary>> = rest
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

  defp wait(fun, left \\ 300) do
    if value = fun.(),
      do: value,
      else:
        (
          assert left > 0
          Process.sleep(10)
          wait(fun, left - 1)
        )
  end

  defp removed(client, wanted) do
    {body, client} = Client.await(client, :play, "remove_entities")
    {count, rest} = Wire.take_varint(body)
    {ids, <<>>} = Enum.map_reduce(1..count, rest, fn _, bytes -> Wire.take_varint(bytes) end)
    remaining = MapSet.difference(wanted, MapSet.new(ids))
    if MapSet.size(remaining) == 0, do: client, else: removed(client, remaining)
  end
end
