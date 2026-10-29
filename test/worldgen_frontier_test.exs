defmodule Valimc.WorldgenFrontierTest do
  @moduledoc """
  Bounded proto memory (VMC-077q): past the cap, cells work does not need
  soon go least recently used first; terrain no decoration wrote into is
  dropped, any other cell spills. The goals' order is the only priority
  (VMC-077u, VMC-077x1): players' focus orders them, urgent calls go first,
  and the work a goal needs follows it.
  """
  use ExUnit.Case, async: true
  alias Valimc.Worldgen.Frontier
  alias Valimc.Worldgen.Frontier.{Dependencies, Memory}

  # Stand-in cells, made in order of `used`: eviction only tells cells in
  # memory from spilled ones.
  defp frontier(chunks, cap) do
    chunks
    |> Enum.sort_by(fn {_, {_, used}} -> used end)
    |> Enum.reduce(%Frontier{kind: :noise, cap: cap}, fn {chunk, {status, _}}, f ->
      Memory.put(f, chunk, make_ref(), status)
    end)
  end

  test "untouched terrain is dropped, decorated chunks and terrain beside them spill" do
    chunks = %{
      # Far from any decoration: dropped.
      {0, 0} => {:terrain, 1},
      # A decorated chunk and terrain it wrote into: spilled.
      {10, 0} => {:decorated, 2},
      {11, 0} => {:terrain, 3},
      # Most recently used: stays, as the room needed is made by then.
      {20, 0} => {:terrain, 9}
    }

    {f, spills} = Memory.evictions(frontier(chunks, 1), 64)

    refute Map.has_key?(f.chunks, {0, 0})
    assert Enum.map(spills, &elem(&1, 0)) == [{10, 0}, {11, 0}]
    assert f.dropped == 1 and f.in_memory == 3

    f = Memory.spilled(f, [{{10, 0}, 0, 100}, {{11, 0}, 100, 80}])
    assert f.chunks[{10, 0}].cell == {:spilled, 0, 100}
    assert f.in_memory == 1 and f.spills == 2
    assert Frontier.stats(f).spilled == 2
    assert Memory.cells(f) == [f.chunks[{20, 0}].cell]
  end

  test "cells near a goal or held by a job stay; under the cap nothing goes" do
    chunks = %{
      {0, 0} => {:terrain, 1},
      {2, 2} => {:terrain, 1},
      {5, 0} => {:terrain, 1},
      {9, 9} => {:terrain, 1}
    }

    f = Frontier.want(frontier(chunks, 1), :player, %{{0, 0} => false})
    f = %{f | busy: %{{9, 9} => make_ref()}}
    {f, []} = Memory.evictions(f, 64)
    # Within 2 of the goal, or held: kept; only {5, 0} could go.
    assert Map.keys(f.chunks) |> Enum.sort() == [{0, 0}, {2, 2}, {9, 9}]

    roomy = %{f | cap: 10}
    assert {^roomy, []} = Memory.evictions(roomy, 64)
  end

  test "a batch spills at most `limit` cells" do
    chunks = for x <- 0..9, into: %{}, do: {{x * 10, 0}, {:decorated, x}}
    {_f, spills} = Memory.evictions(frontier(chunks, 1), 3)
    assert Enum.map(spills, &elem(&1, 0)) == [{0, 0}, {10, 0}, {20, 0}]
  end

  # The chunks of the jobs `next/3` starts, in order (the jobs' closures
  # never run; in a flat world one job per goal, in goal order).
  defp order(f, n) do
    {jobs, _f} = Frontier.next(f, n)
    Enum.map(jobs, & &1.chunk)
  end

  test "a player's own chunk goes first, then the chunks ahead of it" do
    f = %Frontier{kind: :flat, final_after_terrain: true, flat: %{}}
    chunks = [{0, 0}, {3, 0}, {-3, 0}, {0, 5}, {40, 40}]
    f = Frontier.want(f, :region, Map.new(chunks, &{&1, false}))
    # With no player, in key order.
    assert order(f, 5) == [{-3, 0}, {0, 0}, {3, 0}, {0, 5}, {40, 40}]

    f = Frontier.focus(f, :player, {0, 0}, {1.0, 0.0})
    assert order(f, 5) == [{0, 0}, {3, 0}, {-3, 0}, {0, 5}, {40, 40}]

    # A call that waits goes first; a forgotten player orders nothing.
    f = Frontier.want(f, :call, %{{40, 40} => true})
    assert hd(order(f, 5)) == {40, 40}
    f = Frontier.focus(f, :player, nil, nil)
    assert order(f, 5) == [{40, 40}, {-3, 0}, {0, 0}, {3, 0}, {0, 5}]
  end

  test "the work a goal needs follows it, before an earlier goal's, and leaves with it" do
    f = Frontier.want(%Frontier{kind: :noise}, :far, %{{0, 0} => false})
    f = Frontier.want(f, :near, %{{4, 0} => false})
    # With the player at the near goal, its terrain goes first though the far
    # goal was wanted first: its 5 × 5, then the rest of the far goal's.
    f = Frontier.focus(f, :player, {4, 0}, nil)
    terrain = order(f, 60)
    assert Enum.sort(Enum.take(terrain, 25)) == Enum.sort(Frontier.around({4, 0}, 2))

    assert length(terrain) ==
             length(Enum.uniq(Frontier.around({0, 0}, 2) ++ Frontier.around({4, 0}, 2)))

    # Withdrawn: terrain only the near goal needed waits.
    f = Frontier.want(f, :near, %{})
    assert Enum.all?(order(f, 50), fn {x, _} -> x <= 2 end)
  end

  test "a nearer goal's terrain starts before a farther goal's ready decoration" do
    # The far goal's 5 × 5 has terrain, so its first decoration can start.
    f = Frontier.want(%Frontier{kind: :noise}, :far, %{{20, 0} => false})

    f =
      Enum.reduce(Frontier.around({20, 0}, 2), f, fn c, f ->
        Dependencies.made(Memory.put(f, c, make_ref(), :terrain), c)
      end)

    assert {[%{kind: :decorate}], _} = Frontier.next(f, 1)

    # The player is at a goal with nothing made: its terrain goes first.
    f = Frontier.want(f, :near, %{{0, 0} => false})
    f = Frontier.focus(f, :player, {0, 0}, nil)
    assert {[%{kind: :terrain, chunk: {x, _}}], _} = Frontier.next(f, 1)
    assert x in -2..2
  end

  test "decorations nobody needs give their numbers up" do
    f = Frontier.want(%Frontier{kind: :noise}, :old, %{{0, 0} => false, {3, 0} => false})
    assert map_size(f.seqs) == 18

    # The player turned away: the old goals' decorations go.
    f = Frontier.want(f, :old, %{})
    assert f.seqs == %{} and f.deps == %{}

    # Wanted again beside the player: numbered nearest first.
    f = Frontier.focus(f, :player, {6, 0}, nil)
    f = Frontier.want(f, :near, %{{4, 0} => false, {6, 0} => false})
    first = Enum.min_by(f.seqs, &elem(&1, 1)) |> elem(0)
    assert first in Frontier.around({6, 0}, 1)
  end

  test "in request order, a goal's decorations wait for earlier conflicting ones" do
    f = Frontier.want(%Frontier{kind: :noise, serial: true}, :far, %{{0, 0} => false})
    f = Frontier.want(f, :near, %{{4, 0} => false})
    # The near goal's decorations wait for the far goal's within 2, so their
    # chain goes first from its earliest decoration: the far goal's first
    # decoration's terrain, and the near goal's last.
    f = Frontier.focus(f, :player, {4, 0}, nil)
    terrain = order(f, 60)
    assert Enum.take(terrain, 9) == Frontier.around({-1, -1}, 1)
    assert List.last(terrain) == {6, 2}
  end

  test "beside a saved area, chunks are decorated as usual, not made alone" do
    # A region loaded these chunks full (as after a crash lost the proto
    # chunks around them).
    saved = for x <- -4..0, z <- -4..4, do: {x, z}
    f = Frontier.present(%Frontier{kind: :noise}, saved)
    f = Frontier.want(f, :near, %{{1, 0} => false, {2, 0} => false})

    assert f.alone == MapSet.new()
    # The decorations beside the saved chunks wait only for terrain outside it.
    assert Enum.all?(f.deps, fn {_, deps} -> Enum.all?(deps.lacking, &(&1 not in saved)) end)
    assert Map.has_key?(f.deps, {1, 0})
    {jobs, _} = Frontier.next(f, 20)
    assert jobs != [] and Enum.all?(jobs, &(&1.kind == :terrain))
  end
end
