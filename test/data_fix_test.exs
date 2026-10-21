defmodule Valimc.DataFixTest do
  @moduledoc """
  Older chunks upgraded as vanilla 26.3 upgrades them (VMC-028d). Vanilla
  parity over a whole 26.2 world and a case for each fix is stage
  `world_upgrade`.
  """
  use ExUnit.Case, async: true
  alias Valimc.World.{DataFix, Schema}

  defp s(value), do: {:string, value}
  defp c(fields), do: {:compound, fields}
  defp state(name), do: c(%{"Name" => s(name)})

  defp chunk(fields) do
    c(
      Map.merge(
        %{"DataVersion" => {:int, 4903}, "xPos" => {:int, 0}, "zPos" => {:int, 0}},
        fields
      )
    )
  end

  defp upgrade(kind, tag) do
    {:ok, {:compound, fields}} = DataFix.upgrade(kind, tag)
    assert fields["DataVersion"] == {:int, Schema.data_version()}
    fields
  end

  test "versions: 26.2 and 26.3's snapshots upgrade, older and newer are refused" do
    current = Schema.data_version()
    tag = &chunk(%{"DataVersion" => {:int, &1}, "Status" => s("minecraft:full")})
    assert {:ok, _} = DataFix.upgrade(:chunk, tag.(4903))
    assert {:ok, _} = DataFix.upgrade(:chunk, tag.(5010))
    assert DataFix.upgrade(:chunk, tag.(current)) == {:ok, tag.(current)}
    assert DataFix.upgrade(:chunk, tag.(4898)) == {:error, {:older_data_version, 4898}}

    assert DataFix.upgrade(:chunk, tag.(current + 1)) ==
             {:error, {:newer_data_version, current + 1}}

    level = c(%{"Data" => c(%{"DataVersion" => {:int, 4903}})})
    assert DataFix.readable(:level, level) == {:ok, 4903}
  end

  test "block states, signs and pots in a full chunk" do
    palette = [
      state("minecraft:stone"),
      c(%{"Name" => s("minecraft:oak_log"), "Properties" => c(%{"axis" => s("x")})})
    ]

    section =
      c(%{
        "Y" => {:byte, 0},
        "block_states" =>
          c(%{"palette" => {:list, {:compound, Enum.map(palette, &elem(&1, 1))}}}),
        "biomes" => c(%{"palette" => {:list, {:string, ["minecraft:plains"]}}})
      })

    entities = [
      %{"id" => s("minecraft:sign"), "x" => {:int, 1}, "y" => {:int, 2}, "z" => {:int, 3}},
      %{
        "id" => s("minecraft:decorated_pot"),
        "sherds" => {:list, {:string, ["minecraft:brick", "minecraft:angler_pottery_sherd"]}}
      },
      %{"id" => s("minecraft:decorated_pot")},
      %{"id" => s("minecraft:piston"), "blockState" => state("minecraft:piston_head")}
    ]

    fields =
      upgrade(
        :chunk,
        chunk(%{
          "Status" => s("minecraft:full"),
          "sections" => {:list, {:compound, [elem(section, 1)]}},
          "block_entities" => {:list, {:compound, entities}}
        })
      )

    {:list, {:compound, [section]}} = fields["sections"]
    {:list, {:compound, palette}} = elem(section["block_states"], 1)["palette"]

    assert palette == [
             %{"id" => s("minecraft:stone")},
             %{"id" => s("minecraft:oak_log"), "properties" => c(%{"axis" => s("x")})}
           ]

    assert fields["blending_data"] ==
             c(%{"min_section" => {:int, -4}, "max_section" => {:int, 20}})

    {:list, {:compound, [sign, pot, plain_pot, piston]}} = fields["block_entities"]
    assert sign["allow_op_features"] == {:byte, 1}
    brick = c(%{"id" => s("minecraft:brick")})

    assert pot["sherds"] ==
             c(%{
               "back" => brick,
               "left" => c(%{"id" => s("minecraft:angler_pottery_sherd")}),
               "right" => brick,
               "front" => brick
             })

    assert plain_pot["sherds"] ==
             c(%{"back" => brick, "left" => brick, "right" => brick, "front" => brick})

    assert piston["blockState"] == c(%{"id" => s("minecraft:piston_head")})
  end

  test "proto chunk statuses merge into terrain and biomes" do
    section = %{"Y" => {:byte, 1}, "block_states" => c(%{}), "biomes" => c(%{})}

    noise =
      upgrade(
        :chunk,
        chunk(%{
          "Status" => s("minecraft:noise"),
          "Heightmaps" => c(%{}),
          "sections" => {:list, {:compound, [section]}}
        })
      )

    assert noise["Status"] == s("minecraft:biomes")
    refute Map.has_key?(noise, "Heightmaps")
    refute Map.has_key?(noise, "blending_data")
    assert noise["sections"] == {:list, {:compound, [Map.delete(section, "block_states")]}}

    carvers = upgrade(:chunk, chunk(%{"Status" => s("carvers")}))
    assert carvers["Status"] == s("minecraft:terrain")
    assert Map.has_key?(carvers, "blending_data")

    assert upgrade(:chunk, chunk(%{}))["Status"] == s("minecraft:empty")

    refute Map.has_key?(
             upgrade(:chunk, chunk(%{"Status" => s("minecraft:biomes")})),
             "blending_data"
           )
  end

  test "explorer maps, buried treasure maps and components; custom data stays" do
    map = fn type, components ->
      %{
        "id" => s("minecraft:filled_map"),
        "count" => {:int, 1},
        "components" =>
          c(
            Map.merge(
              %{"minecraft:map_decorations" => c(%{"+" => c(%{"type" => s(type)})})},
              components
            )
          )
      }
    end

    legacy = %{"minecraft:item_name" => c(%{"translate" => s("filled_map.monument")})}

    items = [
      map.("minecraft:monument", legacy),
      map.("red_x", %{"minecraft:map_color" => {:int, 3}}),
      %{
        "id" => s("minecraft:map"),
        "count" => {:int, 1},
        "components" =>
          c(%{"minecraft:item_name" => c(%{"translate" => s("filled_map.buried_treasure")})})
      },
      %{
        "id" => s("minecraft:paper"),
        "count" => {:int, 1},
        "components" =>
          c(%{
            "minecraft:swing_animation" => c(%{"type" => s("whack")}),
            "minecraft:custom_data" => c(%{"kept" => c(map.("minecraft:monument", legacy))})
          })
      }
    ]

    fields =
      upgrade(
        :entities,
        c(%{
          "DataVersion" => {:int, 4903},
          "Entities" =>
            {:list,
             {:compound,
              [
                %{
                  "id" => s("minecraft:chest_minecart"),
                  "DisplayState" => state("minecraft:chest"),
                  "Items" => {:list, {:compound, items}}
                }
              ]}}
        })
      )

    {:list, {:compound, [minecart]}} = fields["Entities"]
    assert minecart["DisplayState"] == c(%{"id" => s("minecraft:chest")})
    {:list, {:compound, [monument, treasure, empty, paper]}} = minecart["Items"]
    assert monument["id"] == s("minecraft:ocean_monument_map")
    refute Map.has_key?(elem(monument["components"], 1), "minecraft:item_name")
    assert treasure["id"] == s("minecraft:buried_treasure_map")
    refute Map.has_key?(elem(treasure["components"], 1), "minecraft:map_color")

    assert elem(empty["components"], 1)["minecraft:item_name"] ==
             c(%{"translate" => s("item.minecraft.buried_treasure_map")})

    {:compound, components} = paper["components"]
    assert components["minecraft:attack_animation"] == c(%{"type" => s("whack")})
    assert components["minecraft:interact_animation"] == c(%{"type" => s("whack")})

    assert components["minecraft:custom_data"] ==
             c(%{"kept" => c(map.("minecraft:monument", legacy))})
  end
end
