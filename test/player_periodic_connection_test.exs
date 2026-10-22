defmodule Valimc.PlayerPeriodicConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Effects, Freezing, Health}
  @moduletag :tcp
  alias Valimc.{Connection, Inventory}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [living: 1, state: 1]

  setup do: Valimc.TestPlayer.scope("Effect", {200_000, 981}, survival: {1, false})

  defp tick(pid, settle \\ true),
    do: Valimc.TestPlayer.tick(pid, if(settle, do: :alive, else: false))

  defp login(ctx, expected_effect \\ nil),
    do: Valimc.TestPlayer.login(ctx, before_load: &effect_on_join(&1, &2, expected_effect))

  defp effect_on_join(client, _pid, nil), do: client

  defp effect_on_join(client, pid, expected) do
    {{entity, id, ticks, level, flags}, client} = effect_packet(client)
    assert entity == state(pid).player.entity_id
    assert {id, ticks, level, flags} == expected
    client
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx, opts) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        living: %Valimc.Living{
          freezing: %Freezing{},
          health: %Health{value: Keyword.get(opts, :health, 20.0)},
          air_supply: 300,
          fire_ticks: Keyword.get(opts, :fire, 0),
          effects: Keyword.get(opts, :effects, %{})
        },
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        last_death: nil,
        food: %Valimc.PlayerFood{level: 5, saturation: 0.0}
      })

    Valimc.TestPlayer.save(ctx, player, Keyword.get(opts, :inventory, %Inventory{}))

    for y <- [64, 65],
        do: :ok = Valimc.TestRegion.set_published({floor(ctx.pose.x), y, floor(ctx.pose.z)}, 0)
  end

  defp effect_packet(client) do
    {body, client} = Client.await(client, :play, "update_mob_effect")
    {entity, rest} = Wire.take_varint(body)
    {id, rest} = Wire.take_varint(rest)
    {level, rest} = Wire.take_varint(rest)
    {ticks, <<flags>>} = Wire.take_varint(rest)
    ticks = if ticks >= 2_147_483_648, do: ticks - 4_294_967_296, else: ticks
    {{entity, id, ticks, level, flags}, client}
  end

  defp effect(pid, name, duration, amplifier \\ 0) do
    id = Valimc.Protocol.EffectTypes.id(name)
    {:ok, incoming} = Effects.new(duration, amplifier)
    assert {:ok, true} = Connection.add_effect(pid, id, incoming)
    id
  end

  test "regeneration reads countdown before decrement, ignores stale ticks and restores health/effects together",
       ctx do
    seed(ctx, health: 10.0)
    {client, pid} = login(ctx)
    id = effect(pid, "regeneration", 200)
    stale = tick(pid)
    assert living(pid).health.value == 11.0
    assert state(pid).player.food.exhaustion == 0.0
    send(pid, {:player_tick, stale})
    assert living(pid).health.value == 11.0
    for _ <- 1..49, do: tick(pid)
    assert living(pid).health.value == 11.0
    tick(pid)
    assert living(pid).health.value == 12.0
    assert living(pid).effects[id] == [{149, 0, false, true, true}]
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 12.0 and saved.effects[id] == [{149, 0, false, true, true}]
    {_client, owner} = login(ctx, {id, 149, 0, 6})
    assert living(owner).health.value == 12.0
    assert elem(hd(living(owner).effects[id]), 0) in 148..149
  end

  test "wither can kill and seals post-tick effects with one unchanged durable death drop", ctx do
    helmet = ItemStack.new("iron_helmet")
    seed(ctx, health: 0.5, inventory: %Inventory{slots: %{5 => helmet}})
    {client, pid} = login(ctx)
    id = effect(pid, "wither", 40)
    tick(pid, false)
    wait(fn -> state(pid).life_stage == :dead end)
    {body, _client} = Client.await(client, :play, "player_combat_kill")
    {_entity, message} = Wire.take_varint(body)

    assert {:ok, {:compound, %{"translate" => {:string, "death.attack.wither"}}}, <<>>} =
             Valimc.NBT.take(message)

    assert {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.effects[id] == [{39, 0, false, true, true}]
    assert saved.inventory.slots == %{}
    [view] = Valimc.TestWorld.item_snapshot(ctx.key) |> Map.values()

    {_entity, <<5, 8, _gravity, 8, 7, stack_bytes::binary>>} =
      Wire.take_varint(IO.iodata_to_binary(elem(view.metadata, 1)))

    assert {:ok, ^helmet, <<255>>} = ItemStack.take(stack_bytes)
  end
end
