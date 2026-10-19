defmodule Valimc.ContainerRecoveryConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.{
    Connection,
    GameMode,
    Inventory,
    Players,
    PlayerContainerTransfers,
    PlayerFood,
    PlayerSnapshot,
    PlayerStore
  }

  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, ContainerTransfers}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    key = {80000 + rem(nonce, 10000), 2900}
    base = Path.join(System.tmp_dir!(), "valimc-container-login-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    name = "ChestR#{rem(nonce, 1_000_000_000)}"
    uuid = Connection.offline_uuid(name)
    span = Valimc.config(:region_size) * 16
    position = {elem(key, 0) * span + 40, 64, elem(key, 1) * span + 40}
    inventory = %Inventory{slots: %{36 => ItemStack.new("diamond", 3)}}

    snapshot = %{
      pose: %{
        x: elem(position, 0) + 0.5,
        y: 64.0,
        z: elem(position, 2) + 0.5,
        yaw: 0.0,
        pitch: 0.0
      },
      inventory: inventory,
      game_mode: GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 19.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 300,
      food: %PlayerFood{},
      transfer_sequence: 0,
      outbox: nil
    }

    {:ok, containers, entry} = Containers.create(%Containers{}, key, position, 3)
    {:ok, containers, _} = ContainerTransfers.reserve(containers, uuid)

    intent = %{
      kind: :container,
      key: key,
      request: %{
        source: uuid,
        sequence: 1,
        permit: <<nonce::128>>,
        position: position,
        revision: entry.revision,
        rows: 3,
        slots: entry.slots,
        inventory: inventory,
        action: :quick_move,
        slot: 54,
        button: 0
      }
    }

    {:ok, pending} = PlayerContainerTransfers.prepare(uuid, 0, snapshot, intent)
    {:ok, bytes} = PlayerSnapshot.encode(uuid, pending)
    path = PlayerStore.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    on_exit(fn ->
      for player <- Players.all(),
          player.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for x <- (elem(key, 0) - 1)..(elem(key, 0) + 1),
          z <- (elem(key, 1) - 1)..(elem(key, 1) + 1),
          {registry, supervisor} <- [
            {Valimc.RegionRegistry, Valimc.RegionSupervisor},
            {Valimc.RegionStoreRegistry, Valimc.RegionStoreSupervisor}
          ],
          {pid, _} <- Registry.lookup(registry, {x, z}),
          do: DynamicSupervisor.terminate_child(supervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{
      name: name,
      uuid: uuid,
      base: base,
      key: key,
      path: path,
      containers: containers,
      pending: pending
    }
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    pid = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp wait(check, remaining \\ 500)
  defp wait(_, 0), do: flunk("container login did not reach its expected boundary")

  defp wait(check, remaining) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(check, remaining - 1)
        )
  end

  for applied <- [false, true] do
    test "ordinary login recovers a #{applied} committed container decision before exposing inventory",
         ctx do
      if unquote(applied) do
        {:ok, %{containers: committed}} =
          ContainerTransfers.plan(ctx.containers, ctx.key, ctx.pending.outbox.request, true)

        {:ok, bytes} = Containers.encode(ctx.key, committed)
        Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
      end

      {client, pid} = login(ctx)
      state = :sys.get_state(pid)
      assert state.recovery == nil
      expected = if unquote(applied), do: %{}, else: %{36 => ItemStack.new("diamond", 3)}
      assert state.inventory.slots == expected

      {:ok, containers} =
        Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

      assert containers.receipts[ctx.uuid].sequence == 1
      Client.close(client)

      wait(fn ->
        not Process.alive?(pid) and Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == []
      end)

      {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)

      assert saved.outbox == nil and saved.transfer_sequence == 1 and
               saved.inventory.slots == expected

      {_fresh, next} = login(ctx)
      assert :sys.get_state(next).inventory.slots == expected

      {:ok, after_reconnect} =
        Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

      assert after_reconnect == containers
    end
  end
end
