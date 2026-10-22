defmodule Valimc.MovementFoodConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp
  alias Valimc.Menus.Inventory
  alias Valimc.Player.Food
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [login: 1, state: 1, tick: 1]

  setup do: Valimc.TestPlayer.scope("Travel", {108_000, 988})

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx, opts \\ []) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        living: %Valimc.Living{freezing: %Freezing{}, health: %Health{}, air_supply: 300},
        game_mode: Valimc.Player.GameMode.new(mode),
        abilities: Valimc.Player.Abilities.for_mode(mode),
        motion: %Valimc.Player.Motion{},
        last_death: nil,
        food: Keyword.get(opts, :food, %Food{})
      })

    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    Valimc.TestPlayer.save(ctx, player, inventory)
  end

  defp move(client, position, flags \\ 1) do
    Client.send_raw(client, [
      Wire.frame(
        Data.id(:play, :serverbound, "move_player_pos"),
        <<position.x::float-64, position.y::float-64, position.z::float-64, flags>>,
        client.threshold
      ),
      Wire.frame(Data.id(:play, :serverbound, "client_tick_end"), <<>>, client.threshold)
    ])
  end

  defp moved(pid, position) do
    wait(fn ->
      s = state(pid)

      Map.take(s.player, [:x, :y, :z]) == Map.take(position, [:x, :y, :z])
    end)
  end

  defp command(client, pid, sprinting) do
    Client.send_packet(
      client,
      :play,
      "player_command",
      Wire.varint(0) <> Wire.varint(if(sprinting, do: 1, else: 2)) <> Wire.varint(0)
    )

    wait(fn -> Bitwise.band(state(pid).player.input.shared_flags, 8) != 0 == sprinting end)
  end

  test "accepted sprint consumes the native amount once, drains food on tick and survives reconnect",
       ctx do
    food = %Food{saturation: 0.0, exhaustion: 3.9375}
    seed(ctx, food: food)
    {client, pid} = login(ctx)
    command(client, pid, true)
    target = %{ctx.pose | x: ctx.pose.x + 1.0}
    move(client, target)
    moved(pid, target)
    exhausted = Food.exhaust(food, 0.10000000149011612)
    assert state(pid).player.food == exhausted
    tick(pid)
    assert state(pid).player.food.level == 19 and state(pid).player.food.saturation == 0.0
    {<<20.0::float-32, rest::binary>>, client} = Client.await(client, :play, "set_health")
    assert {19, <<+0.0::float-32>>} = Wire.take_varint(rest)
    saved_food = state(pid).player.food
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.food == saved_food and saved.inventory.slots[36] == ItemStack.new("stone", 7)
    {_client, owner} = login(ctx)
    assert state(owner).player.food == saved_food
  end

  test "movement keeps wire order before a later stop-sprinting command", ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    command(client, pid, true)
    target = %{ctx.pose | x: ctx.pose.x + 0.2}
    move(client, target)
    Client.send_packet(client, :play, "player_command", <<0, 2, 0>>)
    moved(pid, target)
    wait(fn -> Bitwise.band(state(pid).player.input.shared_flags, 8) == 0 end)
    expected = Food.exhaust(%Food{}, 0.019999999552965164)
    assert state(pid).player.food == expected
    next = %{target | x: target.x + 0.2}
    move(client, next)
    moved(pid, next)
    assert state(pid).player.food == expected
  end

  test "speed and collision corrections cannot spend exhaustion", ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    command(client, pid, true)
    move(client, %{ctx.pose | x: ctx.pose.x + 20})
    {body, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", body)
    wait(fn -> not state(pid).teleport_pending end)
    assert state(pid).player.food == %Food{}
    :ok = Valimc.TestRegion.set_published({floor(ctx.pose.x) + 1, 64, floor(ctx.pose.z)}, 1)
    move(client, %{ctx.pose | x: ctx.pose.x + 0.4})
    {body, client} = Client.await(client, :play, "player_position")
    _client = Client.auto_reply(client, :play, "player_position", body)
    wait(fn -> not state(pid).teleport_pending end)
    assert state(pid).player.food == %Food{}
  end
end
