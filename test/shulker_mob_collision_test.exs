defmodule Valimc.ShulkerMobCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Physics.Kernel

  defp scene do
    states = for x <- -8..16, y <- 60..70, z <- -4..4, into: %{}, do: {{x, y, z}, 0}
    {:ok, mover} = Body.new("minecraft:husk")
    mover = %{mover | no_gravity: true, velocity: {4.0, 0.0, 0.0}}
    {:ok, shell} = Body.new("minecraft:shulker")
    shell = %{shell | data: %{shell.data | attach_face: 5, peek: 100, peek_amount: 1.0}}
    {Valimc.World.View.of(states), mover, shell}
  end

  # The kernel's input of a body at `x`, and the box it blocks others with.
  defp kernel(body, x),
    do: Valimc.Native.mob_oracle_body_kernel(Store.body_record(body, <<1::128>>, {x, 64.0, 0.5}))

  defp input(mover, x), do: elem(kernel(mover, x), 0)
  defp box(shell, x), do: elem(kernel(shell, x), 1)

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
        [input(mover, -2.0), input(shell, 0.5)],
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
      | List.duplicate(input(shell, 0.5), 257)
    ]

    ticker = Kernel.mobs_begin(view, mobs, [], nil, boxes)
    assert {{:error, :entity_query_limit}, _} = Kernel.mob_step(ticker, 0, input(mover, -2.0))
    _ = Kernel.mobs_finish(ticker)
  end

  test "external moves of NoAI bodies keep query bounds and do not spend the ticker on refusal" do
    {view, mover, shell} = scene()
    mover = put_in(mover.mob.no_ai, true)
    boxes = for i <- 1..257, do: {i, box(shell, 0.5)}
    own = input(mover, -1.5)
    mobs = [own | List.duplicate(input(shell, 0.5), 257)]
    ticker = Kernel.mobs_begin(view, mobs, [], nil, boxes)
    assert {:error, :entity_query_limit} = Kernel.mob_displace(ticker, 0, own, {0.5, 0.0, 0.0})
    for {i, _} <- boxes, do: :ok = Kernel.mob_collider(ticker, i, {0.5, 64.0, 0.5}, nil)
    assert {:ok, {{-1.0, 64.0, 0.5}, _, _}} = Kernel.mob_displace(ticker, 0, own, {0.5, 0.0, 0.0})
    _ = Kernel.mobs_finish(ticker)
  end

  test "external mover rejects oversized motion and collider sets before reading the world" do
    {view, _, _} = scene()

    body =
      {{0.5, 64.0, 0.5}, {0.3, 1.8}, {0.0, 0.0, 0.0}, {false, 0.6, true, false},
       {0.0, false, true, 0.08, 0.98}}

    cells = Kernel.native(view, {-2.0, 60.0, -2.0, 3.0, 68.0, 3.0})

    assert {:error, :invalid_view} =
             Valimc.Native.physics_displace(cells, body, {1.01, 0.0, 0.0}, [], nil, true)

    boxes = List.duplicate({0.0, 64.0, 0.0, 1.0, 65.0, 1.0}, 257)

    assert {:error, :invalid_view} =
             Valimc.Native.physics_displace(cells, body, {0.1, 0.0, 0.0}, boxes, nil, true)
  end
end
