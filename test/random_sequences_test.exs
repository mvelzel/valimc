defmodule Valimc.RandomSequencesTest do
  @moduledoc """
  The server's random sequences (VMC-044b1): one lessee at a time, a dead
  lessee leaves the sequence as it was, returned states are written and read
  again by a restarted owner.
  """
  use ExUnit.Case, async: true
  alias Valimc.World.RandomSequences

  @moduletag :tmp_dir
  @id "minecraft:trade_set/librarian/level_1"

  defp owner(dir), do: start_supervised!({RandomSequences, dir: dir, seed: 42, name: nil})

  test "a sequence starts as vanilla seeds it and keeps what its lessee returns", %{tmp_dir: dir} do
    owner = owner(dir)
    first = Valimc.Native.loot_sequence(42, 0, @id)
    assert RandomSequences.with(owner, @id, fn s -> {s, {1, 2}} end) == {:ok, first}
    assert RandomSequences.with(owner, @id, fn s -> {s, :unchanged} end) == {:ok, {1, 2}}

    # A lessee that dies returns nothing.
    {pid, ref} =
      spawn_monitor(fn -> RandomSequences.with(owner, @id, fn _ -> exit(:boom) end) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :boom}
    assert RandomSequences.with(owner, @id, fn s -> {s, :unchanged} end) == {:ok, {1, 2}}
  end

  test "a second caller waits for the first lessee's return", %{tmp_dir: dir} do
    owner = owner(dir)
    test = self()

    first =
      Task.async(fn ->
        RandomSequences.with(owner, @id, fn s ->
          send(test, :leased)

          receive do
            :go -> {s, {7, 8}}
          end
        end)
      end)

    assert_receive :leased
    second = Task.async(fn -> RandomSequences.with(owner, @id, fn s -> {s, :unchanged} end) end)
    refute Task.yield(second, 50)
    send(first.pid, :go)
    Task.await(first)
    assert Task.await(second) == {:ok, {7, 8}}
  end

  test "returned states are written and a restarted owner reads them", %{tmp_dir: dir} do
    owner = owner(dir)
    assert {:ok, _} = RandomSequences.with(owner, @id, fn s -> {s, {-5, 9}} end)
    :ok = stop_supervised(RandomSequences)
    assert RandomSequences.read(dir) == {:ok, %{@id => {-5, 9}}}

    owner = owner(dir)
    assert RandomSequences.with(owner, @id, fn s -> {s, :unchanged} end) == {:ok, {-5, 9}}
  end
end

defmodule Valimc.TradeDrawTest do
  @moduledoc """
  A merchant's draw in its group (VMC-044b1): a profession's set at its level
  from its sequence, which advances; an exploration map's unanswered search
  stops the draw and leaves the sequence.
  """
  use ExUnit.Case, async: true
  alias Valimc.World.{RandomSequences, Trades}

  @moduletag :tmp_dir

  test "a librarian draws two offers and a cartographer waits for its map's search",
       %{tmp_dir: dir} do
    owner = start_supervised!({RandomSequences, dir: dir, seed: 7, name: nil})

    librarian = %{
      profession: "minecraft:librarian",
      level: 1,
      villager_type: "minecraft:plains",
      position: {0.5, 64.0, 0.5}
    }

    assert {:ok, [_, _] = first} = Trades.draw(librarian, [], owner)
    assert {:ok, [_, _] = second} = Trades.draw(librarian, [], owner)
    # The sequence moved on (two librarians rarely draw alike; this seed does not).
    refute first == second
    assert Enum.all?(first, &match?(%{uses: 0, reward_exp: true, demand: 0}, &1))

    sequence = "minecraft:trade_set/cartographer/level_2"
    {:ok, before} = RandomSequences.with(owner, sequence, &{&1, :unchanged})
    cartographer = %{librarian | profession: "minecraft:cartographer", level: 2}
    assert {:locate, "minecraft:" <> _, radius} = Trades.draw(cartographer, [], owner)
    assert radius > 0
    assert RandomSequences.with(owner, sequence, &{&1, :unchanged}) == {:ok, before}
    assert {:ok, [_ | _]} = Trades.draw(cartographer, [{"*", {300, 64, -200}}], owner)
  end
end
