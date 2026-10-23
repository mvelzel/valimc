defmodule Valimc.ExplosionConnectionTest do
  @moduledoc """
  A primed TNT exploding six blocks from a survival player (VMC-050a1): the
  player's session takes the hit by its exposure and the difficulty, and its
  connection gets the explode packet with the knockback away from the TNT.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Entity.{Body, Store}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [living: 1]

  setup do
    ctx = Valimc.TestPlayer.scope("Boom", {176_000, 983}, survival: {2, true})
    Valimc.TestScope.isolate(ctx.key, item_simulation: true)
    ctx
  end

  test "the player is hurt and pushed, and sees the explosion", ctx do
    player =
      Map.merge(ctx.pose, %{
        living: %Valimc.Living{health: %Valimc.Living.Health{value: 20.0}},
        game_mode: Valimc.Player.GameMode.new(:survival),
        abilities: Valimc.Player.Abilities.for_mode(:survival),
        motion: %Valimc.Player.Motion{},
        last_death: nil,
        food: %Valimc.Player.Food{level: 20, saturation: 5.0}
      })

    Valimc.TestPlayer.save(ctx, player, %Valimc.Menus.Inventory{})
    {client, pid} = Valimc.TestPlayer.login(ctx)

    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    tnt = %{Body.primed_tnt(3) | velocity: {0.0, 0.0, 0.0}}
    at = {ctx.pose.x + 6.0, ctx.pose.y, ctx.pose.z}
    :ok = Valimc.World.Region.drop_items(owner, [Store.body_record(tnt, <<5::128>>, at)])

    {body, _client} = Client.await(client, :play, "explode", 2_000)

    <<x::float-64, _y::float-64, z::float-64, radius::float-32, _count::signed-32, 1,
      kx::float-64, _ky::float-64, kz::float-64, _rest::binary>> = body

    assert {x, z, radius} == {ctx.pose.x + 6.0, ctx.pose.z, 4.0}
    # Pushed away from the TNT, toward -x.
    assert kx < 0.0 and abs(kz) < 1.0e-9

    Valimc.TestWait.until(fn -> living(pid).health.value < 20.0 end)
    assert living(pid).health.value > 0.0
  end
end
