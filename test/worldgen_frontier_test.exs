defmodule Valimc.WorldgenFrontierTest do
  @moduledoc """
  Bounded proto memory (VMC-077q): past the cap, cells work does not need
  soon go least recently used first; terrain no decoration wrote into is
  dropped, any other cell spills. Players' focus orders the work (VMC-077u).
  """
  use ExUnit.Case, async: true
  alias Valimc.Worldgen.Frontier

  # Stand-in cells: eviction only tells cells in memory from spilled ones.
  defp entry(status, used), do: %{status: status, cell: make_ref(), used: used}

  defp frontier(chunks, cap) do
    %Frontier{kind: :noise, cap: cap, chunks: chunks, in_memory: map_size(chunks)}
  end

  test "untouched terrain is dropped, decorated chunks and terrain beside them spill" do
    chunks = %{
      # Far from any decoration: dropped.
      {0, 0} => entry(:terrain, 1),
      # A decorated chunk and terrain it wrote into: spilled.
      {10, 0} => entry(:decorated, 2),
      {11, 0} => entry(:terrain, 3),
      # Most recently used: stays, as the room needed is made by then.
      {20, 0} => entry(:terrain, 9)
    }

    {f, spills} = Frontier.evictions(frontier(chunks, 1), 64)

    refute Map.has_key?(f.chunks, {0, 0})
    assert Enum.map(spills, &elem(&1, 0)) == [{10, 0}, {11, 0}]
    assert f.dropped == 1 and f.in_memory == 3

    f = Frontier.spilled(f, [{{10, 0}, 0, 100}, {{11, 0}, 100, 80}])
    assert f.chunks[{10, 0}].cell == {:spilled, 0, 100}
    assert f.in_memory == 1 and f.spills == 2
    assert Frontier.stats(f).spilled == 2
    assert Frontier.cells_in_memory(f) == [f.chunks[{20, 0}].cell]
  end

  test "cells near a wanted chunk or held by a job stay; under the cap nothing goes" do
    chunks = %{
      {0, 0} => entry(:terrain, 1),
      {2, 2} => entry(:terrain, 1),
      {5, 0} => entry(:terrain, 1),
      {9, 9} => entry(:terrain, 1)
    }

    f = Frontier.want(frontier(chunks, 1), :player, %{{0, 0} => 1})
    f = %{f | busy: %{{9, 9} => make_ref()}}
    {f, []} = Frontier.evictions(f, 64)
    # Within 2 of the wanted chunk, or held: kept; only {5, 0} could go.
    assert Map.keys(f.chunks) |> Enum.sort() == [{0, 0}, {2, 2}, {9, 9}]

    roomy = %{f | cap: 10}
    assert {^roomy, []} = Frontier.evictions(roomy, 64)
  end

  test "a batch spills at most `limit` cells" do
    chunks = for x <- 0..9, into: %{}, do: {{x * 10, 0}, entry(:decorated, x)}
    {_f, spills} = Frontier.evictions(frontier(chunks, 1), 3)
    assert Enum.map(spills, &elem(&1, 0)) == [{0, 0}, {10, 0}, {20, 0}]
  end

  # The chunks of the jobs `next/3` starts, in order (a flat world: one job
  # per wanted chunk, by priority; the jobs' closures never run).
  defp order(f, n) do
    {jobs, _f} = Frontier.next(f, n)
    Enum.map(jobs, & &1.chunk)
  end

  test "a player's own chunk goes first, then the chunks ahead of it" do
    f = %Frontier{kind: :flat, final_after_terrain: true, flat: %{}}
    chunks = [{0, 0}, {3, 0}, {-3, 0}, {0, 5}, {40, 40}]
    # The region's tickets still name an old center far behind.
    f =
      Frontier.want(
        f,
        :region,
        Map.new(chunks, fn {x, z} -> {{x, z}, (x - 40) ** 2 + (z - 40) ** 2} end)
      )

    assert order(f, 5) == [{40, 40}, {0, 5}, {3, 0}, {0, 0}, {-3, 0}]

    f = Frontier.focus(f, :player, {0, 0}, {1.0, 0.0})
    assert order(f, 5) == [{0, 0}, {3, 0}, {-3, 0}, {0, 5}, {40, 40}]

    # A call that waits stays first; a forgotten player orders nothing.
    f = Frontier.want(f, :call, %{{40, 40} => -1})
    assert hd(order(f, 5)) == {40, 40}
    f = Frontier.focus(f, :player, nil, nil)
    assert order(f, 5) == [{40, 40}, {0, 5}, {3, 0}, {0, 0}, {-3, 0}]
  end
end
