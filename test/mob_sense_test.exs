defmodule Valimc.MobSenseTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, MobMotion}
  alias Valimc.Physics.Kernel
  alias Valimc.World.View

  defp original(view, box, eye) do
    with {:ok, %{water: water, lava: lava}} <- Kernel.fluids(view, box),
         {:ok, eye} <- Kernel.eye_block(view, box, eye) do
      {:ok, {water, lava, eye}}
    end
  end

  defp ticker(view, position) do
    {:ok, body} = Body.new("minecraft:husk")
    Kernel.mobs_begin(view, [MobMotion.kernel(body.type, position, body)], [], nil)
  end

  test "combined sensing matches separate scans for fluid heights and sturdy ceilings" do
    air = Valimc.Data.Blocks.default_state("air")
    stone = Valimc.Data.Blocks.default_state("stone")
    source = Valimc.Data.Blocks.default_state("water")
    flowing = Valimc.Data.Blocks.state("water", %{"level" => "4"})
    falling = Valimc.Data.Blocks.state("water", %{"level" => "8"})
    lava = Valimc.Data.Blocks.default_state("lava")
    bubble = Valimc.Data.Blocks.default_state("bubble_column")

    for fluid <- [air, source, flowing, falling, lava, bubble], ceiling <- [air, stone] do
      states =
        for x <- -4..1, z <- -4..1, y <- 60..69, into: %{} do
          state =
            cond do
              y == 63 -> stone
              y == 64 -> fluid
              y == 65 -> ceiling
              true -> air
            end

          {{x, y, z}, state}
        end

      view = View.of(states)
      ticker = ticker(view, {-1.5, 64.0, -1.5})

      # Eye just under/over the source surface, ordinary eye, and a changed box.
      for y <- [64.0, 64.8], height <- [0.6, 1.95], eye_y <- [64.7, 64.95, 65.62] do
        box = {-1.8, y, -1.8, -1.2, y + height, -1.2}
        eye = {-1.5, eye_y, -1.5}
        assert Kernel.mob_sense(ticker, box, eye) == original(view, box, eye)

        assert Valimc.Native.physics_mobs_sense_dirty(ticker, box, eye) ==
                 Valimc.Native.physics_mobs_sense(ticker, box, eye)
      end

      _ = Kernel.mobs_finish(ticker)
    end
  end

  test "missing cells and degenerate bodies fail as separate reads, without changing the ticker" do
    states = for x <- -2..1, y <- 63..67, z <- -2..1, into: %{}, do: {{x, y, z}, 0}
    view = View.of(Map.delete(states, {-1, 64, -1}))
    ticker = ticker(view, {-0.5, 64.0, -0.5})
    box = {-1.8, 64.0, -1.8, -1.2, 65.95, -1.2}

    assert Kernel.mob_sense(ticker, box, {-1.5, 65.6, -1.5}) ==
             original(view, box, {-1.5, 65.6, -1.5})

    empty = {-0.5, 64.0, -0.5, -0.5, 64.0, -0.5}

    assert Kernel.mob_sense(ticker, empty, {-0.5, 64.0, -0.5}) ==
             original(view, empty, {-0.5, 64.0, -0.5})

    assert Kernel.mobs_finish(ticker) == [{0.0, 0.0, 0.0}]
  end
end
