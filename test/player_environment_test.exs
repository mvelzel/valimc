defmodule Valimc.PlayerEnvironmentTest do
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, Inventory, PlayerEnvironment}
  alias Valimc.Physics.BlockCollisions.Frame
  alias Valimc.Protocol.ItemStack

  test "only due observations advance effects; freezing caps and cooling reaches zero" do
    env = %PlayerEnvironment{frozen_ticks: 139}
    assert PlayerEnvironment.observe(env, true, false, false).frozen_ticks == 139
    frozen = PlayerEnvironment.observe(env, true, true, false)
    assert frozen.frozen_ticks == 140 and frozen.powder_snow
    assert PlayerEnvironment.observe(frozen, true, true, false) == frozen
    assert PlayerEnvironment.observe(frozen, false, true, false).frozen_ticks == 138
    assert PlayerEnvironment.observe(frozen, true, true, true).frozen_ticks == 138

    assert PlayerEnvironment.observe(%PlayerEnvironment{frozen_ticks: 1}, false, true, false).frozen_ticks ==
             0

    refute PlayerEnvironment.active?(%PlayerEnvironment{})
  end

  test "native tag membership applies to equipped armor rather than held items" do
    player = %{game_mode: GameMode.new(:creative)}
    assert PlayerEnvironment.can_freeze?(player, %Inventory{})

    for {slot, name} <- [
          {5, "leather_helmet"},
          {6, "leather_chestplate"},
          {7, "leather_leggings"},
          {8, "leather_boots"}
        ] do
      refute PlayerEnvironment.can_freeze?(player, %Inventory{
               slots: %{slot => ItemStack.new(name)}
             })
    end

    assert PlayerEnvironment.can_freeze?(player, %Inventory{
             slots: %{45 => ItemStack.new("leather_boots")}
           })

    refute PlayerEnvironment.can_freeze?(
             %{player | game_mode: GameMode.new(:spectator)},
             %Inventory{}
           )
  end

  test "body samples use deflated contact, complete cells and bounded work" do
    frame = %Frame{
      states: %{{0, 64, 0} => 30519, {0, 65, 0} => 0, {0, 66, 0} => 0},
      fences: %{},
      entities: %{}
    }

    assert {:ok, true} = PlayerEnvironment.sample(frame, {0.2, 64.0, 0.2, 0.8, 65.8, 0.8})
    assert {:ok, false} = PlayerEnvironment.sample(frame, {0.2, 65.0, 0.2, 0.8, 66.8, 0.8})

    assert {:error, :incomplete_environment_frame} =
             PlayerEnvironment.sample(frame, {0.2, 64.0, 0.2, 1.2, 65.8, 0.8})

    assert {:error, :environment_body_limit} =
             PlayerEnvironment.sample(frame, {0, 0, 0, 1_000_000, 1_000_000, 1_000_000})

    assert {:error, :environment_body_limit} = PlayerEnvironment.sample(frame, {0, 0, 0, 0, 0, 0})
  end

  test "retired clock messages cannot create a simulation tick" do
    clock = Valimc.World.TickClock.new(make_ref(), System.monotonic_time(:millisecond))
    state = %{phase: :play, simulation_clock: clock}
    assert {:noreply, ^state} = Valimc.Connection.handle_info({:player_tick, make_ref()}, state)
  end
end
