defmodule Valimc.FallingBlockTest do
  @moduledoc """
  Falling blocks (VMC-050a2): sand placed in the air falls and lands on the
  floor, sand falling onto a torch drops as an item, concrete powder falling
  into water hardens, and sand on the world's floor stays.
  """
  use ExUnit.Case, async: true
  alias Valimc.Commands.Source
  alias Valimc.Entity.Body

  @key {-4110, 11}
  @x -526_020
  @z 1450
  @y 90

  setup do
    Valimc.TestScope.isolate([@key], item_simulation: true)
    {:ok, owner} = Valimc.TestWorld.owner(@key)
    :ok = Valimc.TestScope.simulate(owner, @key)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(@key), do: Valimc.TestScope.kill(pid)
    end)

    %{owner: owner}
  end

  defp run(input) do
    source = %{Source.rcon() | dimension: :overworld, position: {@x + 0.5, @y * 1.0, @z + 0.5}}
    Valimc.Commands.run(source, input)
    Source.collect(source)
  end

  defp block(name), do: Valimc.Data.Blocks.default_state(name)
  defp at(x, y, z), do: Valimc.TestBlocks.get({x, y, z})
  defp entries(owner), do: Map.values(Valimc.TestRegion.section(owner).entities.store.entries)

  test "sand falls and lands, onto a torch it drops, powder hardens in water", %{owner: owner} do
    assert run("fill #{@x - 4} #{@y - 1} #{@z - 4} #{@x + 4} #{@y - 1} #{@z + 4} stone") =~
             "Successfully filled"

    # Onto the floor.
    assert run("setblock #{@x} #{@y + 5} #{@z} sand") =~ "Changed the block"
    # Onto a torch: it lands in the torch's cell, which it cannot replace.
    assert run("setblock #{@x + 2} #{@y} #{@z} torch") =~ "Changed the block"
    assert run("setblock #{@x + 2} #{@y + 4} #{@z} sand") =~ "Changed the block"
    # Into water.
    assert run("setblock #{@x - 2} #{@y} #{@z} water") =~ "Changed the block"
    assert run("setblock #{@x - 2} #{@y + 4} #{@z} red_concrete_powder") =~ "Changed the block"

    Valimc.TestWait.until(fn ->
      at(@x, @y, @z) == block("sand") and at(@x - 2, @y, @z) == block("red_concrete") and
        Enum.any?(entries(owner), &match?(%{kind: :item}, &1))
    end)

    assert at(@x, @y + 5, @z) == block("air")
    assert at(@x + 2, @y, @z) == block("torch")
    assert at(@x + 2, @y + 4, @z) == block("air")
    [item] = Enum.filter(entries(owner), &match?(%{kind: :item}, &1))
    assert item.stack.item_id == Valimc.Protocol.Data.item("sand") and item.stack.count == 1
    refute Enum.any?(entries(owner), &match?(%{body: %Body{type: "minecraft:falling_block"}}, &1))
  end

  test "an anvil that falls six blocks onto a zombie deals it 10", %{owner: owner} do
    assert run("fill #{@x - 4} #{@y - 1} #{@z - 4} #{@x + 4} #{@y - 1} #{@z + 4} stone") =~
             "Successfully filled"

    assert run("summon zombie #{@x + 0.5} #{@y} #{@z + 0.5}") =~ "Summoned new Zombie"
    assert run("setblock #{@x} #{@y + 6} #{@z} anvil") =~ "Changed the block"

    zombie = fn ->
      Enum.find(entries(owner), &match?(%{body: %Body{type: "minecraft:zombie"}}, &1))
    end

    Valimc.TestWait.until(fn -> zombie.().body.mob.living.health.value < 20.0 end)
    # Two per block fallen past the first: six blocks, 10.
    assert zombie.().body.mob.living.health.value == 10.0
    assert Valimc.Data.Blocks.class(at(@x, @y, @z)) == "AnvilBlock"
  end

  test "a falling block's spawn carries its state and its start" do
    body = Body.falling_block(block("gravel"), {1, 70, 2})
    assert Body.spawn_data(body) == block("gravel")
    assert {:falling_block_start_pos, {1, 70, 2}, {0, 0, 0}} in Body.values(body)
    assert {:ok, ^body} = Body.restore(Body.record(body))
  end
end
