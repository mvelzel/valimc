defmodule Valimc.DragonArenaTest do
  use ExUnit.Case, async: true
  alias Valimc.World.Dragon.{Fight, Podium}

  test "completion is fenced by the dragon and grants one egg and at most twenty gateways" do
    fight = %{Fight.new(42) | dragon: <<45::128>>, podium: {0, 64, 0}}
    assert {^fight, []} = Fight.complete(fight, <<46::128>>)
    {dead, first} = Fight.complete(fight, fight.dragon)
    assert :egg in first and dead.killed and dead.previous_kill
    assert {^dead, []} = Fight.complete(dead, fight.dragon)

    {last, gates} =
      Enum.reduce(2..21, {dead, Enum.filter(first, &match?({:gateway, _}, &1))}, fn _, {f, all} ->
        {f, effects} = Fight.complete(%{f | killed: false}, f.dragon)
        refute :egg in effects
        {f, all ++ Enum.filter(effects, &match?({:gateway, _}, &1))}
      end)

    assert last.gateways == [] and length(Enum.uniq(gates)) == 20
  end

  test "the audience uses a 3-D closed sphere and keeps creative and spectator players" do
    for mode <- [:survival, :creative, :spectator] do
      assert Fight.eligible?(%{alive: true, x: 192.0, y: 128.0, z: 0.0, mode: mode})
    end

    refute Fight.eligible?(%{alive: false, x: 0.0, y: 128.0, z: 0.0})
    refute Fight.eligible?(%{alive: true, x: 192.001, y: 128.0, z: 0.0})
    refute Fight.eligible?(%{alive: true, x: 0.0, y: 321.0, z: 0.0})
  end

  test "four cardinal crystal boxes admit together, including extras, and only their break aborts" do
    fight = %{Fight.new(1) | killed: true, previous_kill: true, podium: {0, 64, 0}}

    crystals =
      for {{x, z}, id} <- Enum.with_index([{0, -3}, {3, 0}, {0, 3}, {-3, 0}, {0, -3}]),
          do: %{uuid: id, box: {x - 0.5, 65.0, z - 0.5, x + 1.5, 67.0, z + 1.5}}

    assert {^fight, []} = Fight.try_respawn(fight, Enum.reject(crystals, &(&1.uuid == 1)))
    {ritual, effects} = Fight.try_respawn(fight, crystals)
    assert ritual.stage == :start and length(ritual.crystals) == 5
    assert effects == [:clear_portal, {:podium, false}]
    assert {^ritual, []} = Fight.try_respawn(ritual, crystals)
    assert {^ritual, []} = Fight.crystal_destroyed(ritual, 999)
    {aborted, effects} = Fight.crystal_destroyed(ritual, 1)
    assert aborted.stage == nil and aborted.killed and aborted.time == 0
    assert effects == [:reset_spike_crystals, {:podium, true}]
    assert {^aborted, ^effects} = Fight.ritual(ritual, [], MapSet.new())
  end

  test "first podium descends through bedrock and clamps above the dimension floor" do
    bedrock = Valimc.Data.Blocks.default_state("bedrock")
    assert Podium.location(70, fn _ -> bedrock end, 0) == {0, 63, 0}
    assert Podium.location(0, fn _ -> 0 end, 0) == {0, 1, 0}
    assert Podium.location(70, fn _ -> 0 end, 0) == {0, 69, 0}
  end
end
