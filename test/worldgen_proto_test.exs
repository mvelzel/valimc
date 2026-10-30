defmodule Valimc.WorldgenProtoTest do
  @moduledoc """
  Proto chunks as native cells (VMC-025d1, VMC-077n): decorating through them
  equals the parity path (`worldgen_decorate`), a decoration reads only its
  3 × 3, a decorated chunk becomes a full column with its block entities,
  ticks and marks, and a cell survives its snapshot encoding.
  """
  use ExUnit.Case, async: true
  alias Valimc.{Native, Worldgen}

  @seed 20_261_020
  @source "minecraft:overworld"

  setup_all do
    {:ok, state} = Worldgen.new(@seed)
    %{state: state}
  end

  defp features do
    Application.app_dir(:valimc, "priv/worldgen/feature_order.json")
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!(@source)
    |> Enum.with_index()
    |> Enum.flat_map(fn {step, s} -> Enum.map(0..(length(step) - 1)//1, &{s, &1}) end)
  end

  defp around({x, z}, r), do: for(dz <- -r..r, dx <- -r..r, do: {x + dx, z + dz})

  # The 5 × 5 around `centre` as cells, its 3 × 3 decorated in `order`.
  defp decorated(state, {x, z}, order) do
    {:ok, cells} = Native.gen_reference(state, @source, {x - 2, z - 2}, 5, order, false)
    cells
  end

  defp terrain(state, chunks) do
    Enum.map(chunks, fn {x, z} ->
      {:ok, cell} = Native.gen_terrain(state, @source, nil, x, z)
      cell
    end)
  end

  test "decorating through proto cells equals the parity path", %{state: state} do
    for centre <- [{-37, 112}] do
      order = around(centre, 1)
      {:ok, want} = Native.worldgen_decorate(state, @source, centre, order, features())
      {:ok, got} = Native.gen_inspect(decorated(state, centre, order))
      assert length(got) == 25

      for {ours, theirs} <- Enum.zip(got, want) do
        assert {ours.x, ours.z} == {theirs.x, theirs.z}
        assert ours.blocks == theirs.blocks, "blocks of #{ours.x}, #{ours.z}"
        assert ours.marks == theirs.marks
        assert ours.block_ticks == theirs.block_ticks
        assert ours.fluid_ticks == theirs.fluid_ticks
        assert ours.block_entities == theirs.block_entities
        assert ours.block_entity_data == theirs.block_entity_data
      end
    end
  end

  test "a decoration reads only its 3 × 3", %{state: state} do
    cells = terrain(state, around({-200, 40}, 1))
    assert {:ok, 0} = Native.gen_decorate(state, @source, nil, {-200, 40}, cells)
  end

  test "a decorated chunk becomes a full column with its extras", %{state: state} do
    centre = {0, 0}
    cell = Enum.at(decorated(state, centre, around(centre, 1)), 12)
    {:ok, [inspected]} = Native.gen_inspect([cell])

    biomes =
      Enum.map(
        Worldgen.biome_names(),
        &Valimc.Protocol.Data.registry_id("minecraft:worldgen/biome", &1)
      )

    {:ok, full} = Native.gen_full(state, cell, biomes)
    assert {full.x, full.z} == centre

    states = List.to_tuple(for <<id::16 <- inspected.blocks>>, do: id)
    {:ok, blocks} = Valimc.World.Blocks.new({0, 0}, %{}, %{centre => full.image})

    for x <- 0..15, z <- 0..15, y <- -64..319 do
      assert Valimc.World.Blocks.get(blocks, {x, y, z}) ==
               elem(states, y + 64 + (x + z * 16) * 384)
    end

    assert Enum.sort(full.marks) == Enum.sort(inspected.marks)
    # Ticks keep only blocks still there, as the state at their position.
    for {{x, y, z} = p, state_id} <- full.block_ticks do
      assert elem(states, y + 64 + (Bitwise.band(x, 15) + Bitwise.band(z, 15) * 16) * 384) ==
               state_id

      assert Enum.any?(inspected.block_ticks, fn {q, _, _, _} -> q == p end)
    end

    assert length(full.fluid_ticks) == length(inspected.fluid_ticks)
  end

  test "generations of one seed run in parallel and agree", %{state: state} do
    chunks = for x <- 0..7, do: {x, 3}
    serial = Enum.map(terrain(state, chunks), &Native.gen_encode/1)

    parallel =
      chunks
      |> Task.async_stream(&Native.gen_encode(hd(terrain(state, [&1]))), timeout: 60_000)
      |> Enum.map(fn {:ok, one} -> one end)

    assert parallel == serial
  end

  test "a cell survives its snapshot encoding", %{state: state} do
    cell = Enum.at(decorated(state, {5, -9}, around({5, -9}, 1)), 12)
    {:ok, encoded} = Native.gen_encode(cell)
    {:ok, decoded} = Native.gen_decode(state, encoded)
    assert Native.gen_encode(decoded) == {:ok, encoded}
    assert Native.gen_inspect([decoded]) == Native.gen_inspect([cell])
  end
end
