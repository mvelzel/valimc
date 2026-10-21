defmodule Valimc.AnvilChunkTest do
  @moduledoc "Chunk NBT to section storage (VMC-021b); the `chunk_sections` oracle checks vanilla worlds."
  use ExUnit.Case, async: true
  alias Valimc.Anvil.Chunk
  alias Valimc.Protocol.Data
  alias Valimc.Registry.Blocks
  alias Valimc.World.Blocks, as: Storage

  @plains Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")
  @desert Data.registry_id("minecraft:worldgen/biome", "minecraft:desert")

  defp chunk(status, sections, version \\ 5023) do
    {:compound,
     %{
       "DataVersion" => {:int, version},
       "xPos" => {:int, -3},
       "zPos" => {:int, 7},
       "Status" => {:string, status},
       "sections" => {:list, {:compound, sections}}
     }}
  end

  # 4 bits per index, 16 per long: every cell takes palette slot `slot`.
  defp filled(slot),
    do:
      :binary.copy(
        <<Enum.reduce(0..15, 0, &Bitwise.bor(&2, Bitwise.bsl(slot, &1 * 4)))::64>>,
        256
      )

  test "full chunks become 24 section specs; missing sections are air in plains" do
    section = %{
      "Y" => {:byte, 0},
      "block_states" =>
        {:compound,
         %{
           "palette" =>
             {:list,
              {:compound,
               [
                 %{"" => {:string, "minecraft:stone"}},
                 %{
                   "id" => {:string, "minecraft:oak_log"},
                   "properties" => {:compound, %{"axis" => {:string, "x"}}}
                 }
               ]}},
           "data" => {:long_array, filled(1)}
         }},
      "biomes" => {:compound, %{"palette" => {:list, {:string, ["minecraft:desert"]}}}}
    }

    light_only = %{"Y" => {:byte, 20}, "SkyLight" => {:byte_array, :binary.copy(<<255>>, 2048)}}

    assert {{:ok, %{chunk: {-3, 7}, sections: specs}}, cache} =
             Chunk.column(chunk("minecraft:full", [section, light_only]))

    assert length(specs) == 24
    stone = Blocks.default_state("stone")
    log = Blocks.state("oak_log", %{"axis" => "x"})
    assert Enum.at(specs, 4) == {[stone, log], filled(1), 4, [@desert], <<>>, 0}
    assert Enum.at(specs, 0) == {[0], <<>>, 0, [@plains], <<>>, 0}
    assert map_size(cache) == 2

    {:ok, blocks} = Storage.new(Valimc.World.region_key({-3, 7}))
    assert :ok = Valimc.Native.put_column(blocks.ref, -3, 7, specs)
    assert Storage.get(blocks, {-48, 0, 112}) == log
    assert Storage.get(blocks, {-48, -64, 112}) == 0
    assert {:ok, states, biomes} = Storage.dump_column(blocks, {-3, 7})
    assert byte_size(states) == 24 * 4096 * 2 and byte_size(biomes) == 24 * 64 * 2
    assert binary_part(biomes, 4 * 128, 2) == <<@desert::16>>
  end

  test "other statuses are skipped; bad data versions and palettes are errors" do
    assert {{:skip, "minecraft:noise"}, _} = Chunk.column(chunk("minecraft:noise", []))

    assert {{:error, {:older_data_version, 4000}}, _} =
             Chunk.column(chunk("minecraft:full", [], 4000))

    bad = fn states ->
      Chunk.column(
        chunk("minecraft:full", [%{"Y" => {:byte, 1}, "block_states" => {:compound, states}}])
      )
      |> elem(0)
    end

    assert bad.(%{"palette" => {:list, {:string, ["minecraft:not_a_block"]}}}) ==
             {:error, :unknown_block_state}

    assert bad.(%{"palette" => {:list, {:string, ["modded:block"]}}}) ==
             {:error, :unknown_block_state}

    assert bad.(%{"palette" => {:list, {:string, ["minecraft:stone", "minecraft:dirt"]}}}) ==
             {:error, :missing_section_data}

    assert bad.(%{
             "palette" =>
               {:list,
                {:compound,
                 [
                   %{
                     "id" => {:string, "minecraft:oak_log"},
                     "properties" => {:compound, %{"axis" => {:string, "w"}}}
                   }
                 ]}}
           }) == {:error, :unknown_block_state}
  end

  test "packed data that does not fit the palette is refused by the store" do
    {:ok, blocks} = Storage.new(Valimc.World.region_key({-3, 7}))
    air = {[0], <<>>, 0, [@plains], <<>>, 0}
    short = {[1, 2], :binary.copy(<<0>>, 8), 4, [@plains], <<>>, 0}

    assert {:error, _} =
             Valimc.Native.put_column(blocks.ref, -3, 7, [short | List.duplicate(air, 23)])

    assert {:error, _} = Valimc.Native.put_column(blocks.ref, -3, 7, List.duplicate(air, 23))
  end
end
