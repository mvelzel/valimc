defmodule Valimc.PlayerMiningConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  # Mining tool rules, loot and attempt timing are compared by the mining oracles;
  # these tests guard the live attempt, its break and its drops around them.

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-mining-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {50_000 + rem(nonce, 3_333) * 3, 700}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    target = {floor(pose.x), 65, floor(pose.z) + 3}
    name = "Dig#{nonce}"
    uuid = Connection.offline_uuid(name)
    # Player ticks come only from the test's own tick messages (VMC-073).
    Valimc.TestScope.isolate([uuid, Connection.offline_uuid(name <> "B")], player_ticks: :manual)

    on_exit(fn ->
      for player <- Players.all(),
          player.name in [name, name <> "B"],
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      Application.put_env(:valimc, :world_path, previous)
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{base: base, key: key, pose: pose, target: target, name: name, uuid: uuid}
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun), do: Valimc.TestWait.until(fun)

  defp seed(ctx, slots, block \\ Data.block("stone")) do
    player =
      Map.merge(ctx.pose, %{
        living: %Valimc.Living{freezing: %Freezing{}, health: %Health{}, air_supply: 300},
        game_mode: GameMode.new(:survival),
        abilities: Valimc.PlayerAbilities.for_mode(:survival),
        motion: %Valimc.PlayerMotion{},
        last_death: nil,
        food: %Valimc.PlayerFood{}
      })

    {:ok, bytes} =
      PlayerState.encode(ctx.uuid, PlayerState.capture(player, %Inventory{slots: slots}))

    path = Valimc.Player.Storage.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    :ok = Valimc.TestBlocks.set(ctx.target, block)
  end

  # Retire wall timers while driving the real owner handler with single-use tokens.
  defp park(pid) do
    Valimc.TestConn.replace(pid, fn s ->
      clock = %{
        s.simulation_clock
        | token: {s.simulation_clock.epoch, make_ref()},
          deadline: System.monotonic_time(:millisecond) + 60_000
      }

      %{s | simulation_clock: clock}
    end)
  end

  defp tick(pid) do
    before =
      Valimc.TestConn.replace(pid, fn s ->
        %{
          s
          | simulation_clock: %{
              s.simulation_clock
              | deadline: System.monotonic_time(:millisecond)
            }
        }
      end)

    send(pid, {:player_tick, before.simulation_clock.token})
    assert state(pid).simulation_clock.tick == before.simulation_clock.tick + 1
    park(pid)
  end

  defp ticks(pid, count), do: Enum.each(1..count, fn _ -> tick(pid) end)

  # Tick the players until `fun` holds; jobs and saves answer between ticks. Each
  # tick waits for its geometry, so a loaded host gets a longer deadline.
  defp tick_until(pids, fun) do
    Valimc.TestWait.until(
      fn ->
        fun.() or
          (
            Enum.each(List.wrap(pids), &tick/1)
            false
          )
      end,
      60_000
    )
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    pid = wait(fn -> Enum.find(Players.all(), &(&1.name == ctx.name)) end).pid
    park(pid)
    client = Client.load_world(client)
    on_exit(fn -> Client.close(client) end)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    Client.send_packet(
      client,
      :play,
      "move_player_pos",
      <<ctx.pose.x::float-64, ctx.pose.y::float-64, ctx.pose.z::float-64, 1>>
    )

    tick_until(pid, fn ->
      s = state(pid)
      s.player.motion.on_ground and s.pose_checked != nil and not s.teleport_pending
    end)

    {client, pid}
  end

  defp action(client, action, position, sequence) do
    Client.send_packet(client, :play, "player_action", [
      Wire.varint(ItemTypes.action_id(action)),
      Wire.position(position),
      <<1>>,
      Wire.varint(sequence)
    ])
  end

  defp finished(pid), do: state(pid).mining == nil

  # The drops as their owner's frames hold them, once it wrote them.
  defp drops(ctx) do
    {:ok, {pid, _}} = Valimc.TestWorld.item_owner(ctx.key)
    :ok = Valimc.World.Region.flush(pid)
    Enum.map(Valimc.TestDisk.read(ctx.base, ctx.key, :items).records, & &1.stack)
  end

  defp reconnect(ctx, client) do
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    login(ctx)
  end

  defp instant(name, enchantments \\ %{}) do
    %{
      ItemStack.new(name)
      | components: %{
          "minecraft:enchantments" => Map.put(enchantments, "minecraft:efficiency", 255)
        }
    }
  end

  test "active ticks never destroy without stop; committed drops and wear survive a real reconnect",
       ctx do
    seed(ctx, %{36 => ItemStack.new("iron_pickaxe")})
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    tick_until(pid, fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    ticks(pid, 12)
    assert Valimc.TestBlocks.get(ctx.target) == Data.block("stone")
    action(client, "stop_destroy_block", ctx.target, 2)
    tick_until(pid, fn -> finished(pid) and Valimc.TestBlocks.get(ctx.target) == 0 end)
    assert Inventory.held(state(pid).inventory, :main).components["minecraft:damage"] == 1
    assert drops(ctx) == [ItemStack.new("cobblestone")]

    {_fresh, pid} = reconnect(ctx, client)
    assert Inventory.held(state(pid).inventory, :main).components["minecraft:damage"] == 1
    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
    assert Valimc.TestBlocks.get(ctx.target) == 0
  end

  test "nearby peers receive changed cracks and competing attempts commit only one drop and wear",
       ctx do
    tool = ItemStack.new("iron_pickaxe")
    seed(ctx, %{36 => tool})
    peer = %{ctx | name: ctx.name <> "B", uuid: Connection.offline_uuid(ctx.name <> "B")}
    seed(peer, %{36 => tool})
    {client, pid} = login(ctx)
    {other, other_pid} = login(peer)
    action(client, "start_destroy_block", ctx.target, 1)
    tick_until(pid, fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    {body, _other} = Client.await(other, :play, "block_destruction")
    {entity, body} = Wire.take_varint(body)
    {position, <<stage>>} = Wire.take_position(body)
    assert entity == state(pid).player.entity_id and position == ctx.target and stage in 0..9
    action(other, "start_destroy_block", ctx.target, 1)

    tick_until(other_pid, fn -> match?(%{attempt: %{phase: :active}}, state(other_pid).mining) end)

    Enum.each(1..12, fn _ -> Enum.each([pid, other_pid], &tick/1) end)
    action(client, "stop_destroy_block", ctx.target, 2)
    action(other, "stop_destroy_block", ctx.target, 2)

    tick_until([pid, other_pid], fn ->
      finished(pid) and finished(other_pid) and Valimc.TestBlocks.get(ctx.target) == 0
    end)

    damages =
      for owner <- [pid, other_pid],
          do:
            Map.get(
              Inventory.held(state(owner).inventory, :main).components,
              "minecraft:damage",
              0
            )

    assert Enum.sort(damages) == [0, 1]
    assert drops(ctx) == [ItemStack.new("cobblestone")]
  end

  test "filled chest mining consumes only tool wear while its owner releases exact stored patches",
       ctx do
    alias Valimc.World.Containers

    stored = %{
      ItemStack.new("diamond", 3)
      | components: %{"minecraft:custom_name" => {:string, "Saved diamonds"}}
    }

    {:ok, chest} = Valimc.ChestPlacement.single_state(0.0, 0)
    {:ok, containers, entry} = Containers.create(%Containers{}, ctx.key, ctx.target, 3)

    {:ok, containers, _} =
      Containers.replace(containers, ctx.target, entry.revision, put_elem(entry.slots, 0, stored))

    {:ok, bytes} = Containers.encode(ctx.key, containers)
    File.mkdir_p!(ctx.base)
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
    Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, %{ctx.target => chest})

    seed(ctx, %{36 => instant("diamond_axe")}, chest)
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    tick_until(pid, fn -> finished(pid) and Valimc.TestBlocks.get(ctx.target) == 0 end)
    expected = Enum.sort_by([ItemStack.new("chest"), stored], & &1.item_id)
    assert Enum.sort_by(drops(ctx), & &1.item_id) == expected
    assert Inventory.held(state(pid).inventory, :main).components["minecraft:damage"] == 1

    {:ok, containers} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    assert containers.entries == %{} and containers.sequence == 3

    {_fresh, fresh_pid} = reconnect(ctx, client)
    assert Inventory.held(state(fresh_pid).inventory, :main).components["minecraft:damage"] == 1
    assert Enum.sort_by(drops(ctx), & &1.item_id) == expected
  end
end
