defmodule Valimc.ShulkerMobCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, MobMotion}
  alias Valimc.Physics.Kernel

  defp scene do
    states = for x <- -8..16, y <- 60..70, z <- -4..4, into: %{}, do: {{x, y, z}, 0}
    {:ok, mover} = Body.new("minecraft:husk")
    mover = %{mover | no_gravity: true, velocity: {4.0, 0.0, 0.0}}
    {:ok, shell} = Body.new("minecraft:shulker")
    shell = %{shell | data: %{shell.data | attach_face: 5, peek: 100, peek_amount: 1.0}}
    {Valimc.World.View.of(states), mover, shell}
  end

  defp input(mover, x), do: MobMotion.kernel(mover.type, {x, 64.0, 0.5}, mover)
  defp box(shell, x), do: Valimc.AI.Mobs.Shulker.collider(shell, {x, 64.0, 0.5})

  defp step(ticker, mover, x) do
    {{:ok, %{mob: %{position: {x, _, _}}}}, _} = Kernel.mob_step(ticker, 0, input(mover, x))
    x
  end

  test "a ticker sees lid changes, teleport across grid cells and collider removal before the next mover" do
    {view, mover, shell} = scene()
    closed = %{shell | data: %{shell.data | peek: 0, peek_amount: 0.0}}

    ticker =
      Kernel.mobs_begin(
        view,
        [input(mover, -2.0), MobMotion.kernel(shell.type, {0.5, 64.0, 0.5}, shell)],
        [],
        nil,
        [{1, box(closed, 0.5)}]
      )

    :ok = Kernel.mob_collider(ticker, 1, {0.5, 64.0, 0.5}, box(shell, 0.5))
    assert_in_delta step(ticker, mover, -2.0), -1.3, 1.0e-7
    :ok = Kernel.mob_collider(ticker, 1, {10.5, 64.0, 0.5}, box(shell, 10.5))
    assert step(ticker, mover, -2.0) == 2.0
    assert_in_delta step(ticker, mover, 8.0), 8.7, 1.0e-7
    :ok = Kernel.mob_collider(ticker, 1, {10.5, 64.0, 0.5}, nil)
    assert step(ticker, mover, 8.0) == 12.0
    _ = Kernel.mobs_finish(ticker)
  end

  test "too many nearby solid boxes refuse the moving mob's tick" do
    {view, mover, shell} = scene()
    boxes = for i <- 1..257, do: {i, box(shell, 0.5)}

    mobs = [
      input(mover, -2.0)
      | List.duplicate(MobMotion.kernel(shell.type, {0.5, 64.0, 0.5}, shell), 257)
    ]

    ticker = Kernel.mobs_begin(view, mobs, [], nil, boxes)
    assert {{:error, :entity_query_limit}, _} = Kernel.mob_step(ticker, 0, input(mover, -2.0))
    _ = Kernel.mobs_finish(ticker)
  end
end
