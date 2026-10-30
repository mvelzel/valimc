defmodule Valimc.ExplosionTest do
  @moduledoc """
  Explosions and primed TNT (VMC-050a1): a primed TNT falls and burns its
  fuse, then blows one crater across two owners, primes the TNT it reaches,
  hurts and pushes a zombie beside it and leaves what it cannot break.
  """
  use ExUnit.Case, async: true
  alias Valimc.Commands.Source
  alias Valimc.Entity.{Body, Store}
  alias Valimc.World.{Explosion, Region}

  # Two regions side by side: x -524800..-524673 and -524672..-524545, z 1152..1279.
  @keys [{-4100, 9}, {-4099, 9}]
  @line -524_672
  @y 80
  @z 1200

  setup do
    Valimc.TestScope.isolate(@keys, item_simulation: true)

    owners =
      Map.new(@keys, fn key ->
        {:ok, owner} = Valimc.TestWorld.owner(key)
        :ok = Valimc.TestScope.simulate(owner, key)
        {key, owner}
      end)

    on_exit(fn ->
      for key <- @keys,
          {pid, _} <- Valimc.TestWorld.registered(key),
          do: Valimc.TestScope.kill(pid)
    end)

    %{owners: owners}
  end

  defp run(input) do
    source = %{Source.rcon() | dimension: :overworld, position: {@line + 0.5, @y * 1.0, @z + 0.5}}
    Valimc.Commands.run(source, input)
    Source.collect(source)
  end

  defp block(name), do: Valimc.Data.Blocks.default_state(name)
  defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

  test "a primed TNT on the line between two owners blows one crater", %{owners: owners} do
    east = owners[{-4099, 9}]
    # Two groups: the crater crosses a group line.
    refute elem(east, 0) == elem(owners[{-4100, 9}], 0)

    assert run("fill #{@line - 6} #{@y - 5} #{@z - 5} #{@line + 5} #{@y - 1} #{@z + 5} stone") =~
             "Successfully filled"

    assert run("setblock #{@line + 1} #{@y - 1} #{@z + 1} tnt") =~ "Changed the block"
    assert run("setblock #{@line} #{@y - 2} #{@z} obsidian") =~ "Changed the block"
    assert run("summon zombie #{@line + 5.5} #{@y} #{@z + 0.5}") =~ "Summoned new Zombie"

    record =
      Store.body_record(%{Body.primed_tnt(4) | velocity: {0.0, 0.0, 0.0}}, <<9::128>>, {
        @line * 1.0,
        @y * 1.0,
        @z + 0.5
      })

    :ok = Region.drop_items(east, [record])

    Valimc.TestWait.until(fn ->
      Valimc.TestBlocks.get({@line - 1, @y - 1, @z}) == block("air") and
        Valimc.TestBlocks.get({@line, @y - 1, @z}) == block("air")
    end)

    # The obsidian under the centre and the stone far from it stand.
    assert Valimc.TestBlocks.get({@line, @y - 2, @z}) == block("obsidian")
    assert Valimc.TestBlocks.get({@line - 6, @y - 5, @z - 5}) == block("stone")

    entries = store(east).entries |> Map.values() |> Enum.map(&Valimc.TestBodies.entry/1)
    # The TNT it reached primes with a short fuse; the primed one is gone.
    assert [%{body: %Body{data: %{fuse: fuse}}}] =
             Enum.filter(entries, &match?(%{body: %Body{type: "minecraft:tnt"}}, &1))

    assert fuse in 1..29
    refute Enum.any?(entries, &(&1.entity.uuid == <<9::128>>))

    [zombie] = Enum.filter(entries, &match?(%{body: %Body{type: "minecraft:zombie"}}, &1))
    assert zombie.body.mob.living.health.value < 20.0
    assert zombie.body.velocity != {0.0, 0.0, 0.0}
  end

  test "an explosion's plan breaks only reached solid cells and splits by region" do
    explosion = %Explosion{center: {@line + 0.0, @y + 0.06, @z + 0.5}, radius: 4.0, decay: false}
    stone = block("stone")

    cells = [
      {{@line - 1, @y - 1, @z}, stone},
      {{@line, @y - 1, @z}, stone},
      {{@line, @y, @z}, block("air")}
    ]

    parts = Explosion.plan(explosion, cells)

    assert Map.keys(parts) |> Enum.sort() == @keys
    assert parts[{-4100, 9}].edits == %{{@line - 1, @y - 1, @z} => block("air")}
    assert parts[{-4099, 9}].expected == %{{@line, @y - 1, @z} => stone}
    # Without decay every stone drops cobblestone, merged per region by where it fell.
    drops = Enum.flat_map(Map.values(parts), & &1.entities)
    assert length(drops) in 1..2
    assert Enum.sum(Enum.map(drops, & &1.stack.count)) == 2
  end
end
