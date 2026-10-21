defmodule Valimc.WorldgenProtoTest do
  @moduledoc """
  Encoded proto chunks (VMC-025d1): decorating through them equals the parity
  path (`worldgen_decorate`), and a decorated chunk becomes a full column with
  its block entities, ticks and marks.
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

  # The 5 × 5 around `centre` through encoded chunks, its 3 × 3 decorated in
  # `order`: every chunk as `worldgen_decorate` reports it.
  defp through_protos(state, centre, order) do
    {:ok, terrain} = Native.worldgen_proto_terrain(state, @source, around(centre, 2))
    {:ok, {touched, 0}} = Native.worldgen_proto_decorate(state, images(terrain), order)
    decorated = Map.merge(by_chunk(terrain), by_chunk(touched))

    {:ok, chunks} =
      Native.worldgen_proto_inspect(state, Enum.map(around(centre, 2), &decorated[&1]))

    chunks
  end

  defp images(list), do: Enum.map(list, fn {_, _, image} -> image end)
  defp by_chunk(list), do: Map.new(list, fn {x, z, image} -> {{x, z}, image} end)

  test "decorating through encoded proto chunks equals the parity path", %{state: state} do
    for centre <- [{0, 0}, {-37, 112}, {803, -1590}] do
      order = around(centre, 1)
      {:ok, want} = Native.worldgen_decorate(state, @source, centre, order, features())
      got = through_protos(state, centre, order)
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

  test "decoding an encoded chunk and decorating nothing touches nothing", %{state: state} do
    {:ok, terrain} = Native.worldgen_proto_terrain(state, @source, around({5, 5}, 1))
    {:ok, {touched, 0}} = Native.worldgen_proto_decorate(state, images(terrain), [{5, 5}])
    assert touched != []
    {:ok, {again, 0}} = Native.worldgen_proto_decorate(state, images(touched), [])
    assert again == []
  end

  test "only the chunks decoration writes into come back, and reads stay in the 3 × 3",
       %{state: state} do
    # The 3 × 3 alone: decoration reads no chunk outside it.
    {:ok, terrain} = Native.worldgen_proto_terrain(state, @source, around({-200, 40}, 1))

    {:ok, {touched, lenient}} =
      Native.worldgen_proto_decorate(state, images(terrain), [{-200, 40}])

    assert lenient == 0
    assert {-200, 40} in Enum.map(touched, fn {x, z, _} -> {x, z} end)
    assert length(touched) <= 9
  end

  test "a decorated chunk becomes a full column with its extras", %{state: state} do
    centre = {0, 0}
    order = around(centre, 1)
    {:ok, terrain} = Native.worldgen_proto_terrain(state, @source, around(centre, 2))
    {:ok, {touched, 0}} = Native.worldgen_proto_decorate(state, images(terrain), order)
    image = by_chunk(touched)[centre]
    {:ok, [inspected]} = Native.worldgen_proto_inspect(state, [image])

    biomes =
      Enum.map(
        Worldgen.biome_names(),
        &Valimc.Protocol.Data.registry_id("minecraft:worldgen/biome", &1)
      )

    {:ok, [full]} = Native.worldgen_proto_full(state, [image], biomes)
    assert {full.x, full.z} == centre
    assert length(full.heights) == 256

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
    {:ok, serial} = Native.worldgen_proto_terrain(state, @source, chunks)

    parallel =
      chunks
      |> Task.async_stream(
        fn c ->
          {:ok, [one]} = Native.worldgen_proto_terrain(state, @source, [c])
          one
        end,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, one} -> one end)

    assert parallel == serial
  end
end
