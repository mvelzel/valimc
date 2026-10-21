defmodule Valimc.PlayerEquipmentConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp
  alias Valimc.{Inventory, Players, PlayerSnapshot, PlayerStore}
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-equipment-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {157_000 + rem(nonce, 3_333) * 3, 650}
    names = for suffix <- ["A", "B"], do: "Equip#{nonce}#{suffix}"
    {rx, rz} = key
    pos = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

    for {name, index} <- Enum.with_index(names) do
      uuid = Valimc.Connection.offline_uuid(name)
      pose = %{pos | x: pos.x + index * 2}
      path = PlayerStore.path(base, uuid)
      {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(pose, Inventory.new()))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    on_exit(fn ->
      for player <- Players.all(),
          player.name in names,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for name <- names,
          {pid, _} <-
            Registry.lookup(Valimc.PlayerStoreRegistry, Valimc.Connection.offline_uuid(name)),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for x <- (rx - 1)..(rx + 3),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{names: names, key: key, pos: pos}
  end

  defp login(name) do
    {_, client} = Client.login(name)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    player = Enum.find(Players.all(), &(&1.name == name))
    Client.send_packet(client, :play, "player_loaded", <<>>)
    {client, player.pid}
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx, name, inventory, mode \\ :creative) do
    uuid = Valimc.Connection.offline_uuid(name)

    player =
      Map.merge(ctx.pos, %{
        living: %Valimc.Living{freezing: %Freezing{}, health: %Health{}, air_supply: 300},
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        last_death: nil,
        food: %Valimc.PlayerFood{level: 5, saturation: 0.0}
      })

    {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(player, inventory))
    File.write!(PlayerStore.path(Valimc.config(:world_path), uuid), bytes)
  end

  defp await_slot(client, entity, slot, stack) do
    if Map.has_key?(get_in(client, [:equipment, entity]) || %{}, slot) and
         get_in(client, [:equipment, entity, slot]) == stack do
      client
    else
      {id, body, client} = Client.read(client)
      name = Data.name(:play, :clientbound, id)
      await_slot(Client.auto_reply(client, :play, name, body), entity, slot, stack)
    end
  end

  defp write_slot(client, pid, slot, stack) do
    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<slot::signed-16>>,
      ItemStack.encode(stack, :untrusted)
    ])

    wait(fn -> Inventory.get(state(pid).inventory, slot) == stack end)
  end

  test "initial and changed hands/armor replicate while inventory authority stays local", ctx do
    [first, second] = ctx.names
    bread = ItemStack.new("bread", 2)
    helmet = ItemStack.new("iron_helmet")
    bowl = ItemStack.new("bowl")
    seed(ctx, first, %Inventory{slots: %{36 => bread, 37 => bowl, 5 => helmet}})
    {sender, pid} = login(first)
    {receiver, _} = login(second)
    entity = state(pid).player.entity_id
    receiver = receiver |> await_slot(entity, 0, bread) |> await_slot(entity, 5, helmet)
    Client.send_packet(sender, :play, "set_carried_item", <<1::signed-16>>)
    wait(fn -> state(pid).inventory.selected == 1 end)
    receiver = await_slot(receiver, entity, 0, bowl)
    patched = %{bread | count: 3, components: %{"minecraft:enchantment_glint_override" => true}}
    write_slot(sender, pid, 45, patched)
    receiver = await_slot(receiver, entity, 1, patched)
    write_slot(sender, pid, 5, nil)
    receiver = await_slot(receiver, entity, 5, nil)
    assert state(pid).inventory.slots[36] == bread
    assert state(pid).player.equipment == %{0 => bowl, 1 => patched}
    # Departing observers remove their cached view with the existing player lifecycle.
    Client.close(receiver)
    wait(fn -> Enum.all?(Players.all(), &(&1.name != second)) end)
    Client.close(sender)

    wait(fn ->
      Registry.lookup(Valimc.PlayerStoreRegistry, Valimc.Connection.offline_uuid(first)) == []
    end)

    {_sender, fresh} = login(first)
    {receiver, _} = login(second)
    entity = state(fresh).player.entity_id
    _receiver = receiver |> await_slot(entity, 0, bowl) |> await_slot(entity, 1, patched)
    assert state(fresh).inventory.slots[36] == bread and state(fresh).inventory.selected == 1
  end

  test "use animation receives current held equipment first and completion clears the consumed hand",
       ctx do
    [first, second] = ctx.names
    # The eater's ticks come only from this test, not 32 real ticks of eating.
    Valimc.TestScope.isolate(Valimc.Connection.offline_uuid(first), player_ticks: :manual)
    soup = ItemStack.new("mushroom_stew")
    seed(ctx, first, %Inventory{slots: %{45 => soup}}, :survival)
    {sender, pid} = login(first)
    {receiver, _} = login(second)
    entity = state(pid).player.entity_id
    receiver = await_slot(receiver, entity, 1, soup)
    Client.send_packet(sender, :play, "use_item", <<1, 1, 0::float-32, 0::float-32>>)
    wait(fn -> state(pid).active_use != nil end)
    receiver = await_use(receiver, entity, 3, soup)
    tick_until(pid, fn -> state(pid).active_use == nil end)
    receiver = await_slot(receiver, entity, 1, ItemStack.new("bowl"))
    _receiver = await_use(receiver, entity, 2, ItemStack.new("bowl"))
    assert state(pid).inventory.slots[45] == ItemStack.new("bowl")
    assert state(pid).player.food.level == 11
  end

  defp tick_until(pid, done?, remaining \\ 64) do
    if done?.() do
      :ok
    else
      assert remaining > 0, "use did not finish"

      before =
        :sys.replace_state(pid, fn s ->
          %{
            s
            | simulation_clock: %{
                s.simulation_clock
                | deadline: System.monotonic_time(:millisecond)
              }
          }
        end)

      send(pid, {:player_tick, before.simulation_clock.token})
      wait(fn -> state(pid).simulation_clock.tick > before.simulation_clock.tick end)
      tick_until(pid, done?, remaining - 1)
    end
  end

  defp await_use(client, entity, flags, held) do
    if get_in(client, [:entity_use, entity]) == flags do
      assert get_in(client, [:equipment, entity, 1]) == held
      client
    else
      {id, body, client} = Client.read(client)
      name = Data.name(:play, :clientbound, id)
      await_use(Client.auto_reply(client, :play, name, body), entity, flags, held)
    end
  end
end
