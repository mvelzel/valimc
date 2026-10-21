defmodule Valimc.Block.BuddingAmethyst do
  @moduledoc """
  Budding amethyst (`BuddingAmethystBlock`): one random tick in five picks a face
  and starts a small bud in air or full water there, or grows the bud already
  facing out of that face (small, medium, large, cluster).
  """
  use Valimc.Block.Behaviour
  alias Valimc.Registry.{BlockFacts, Blocks}

  # Vanilla `Direction.values()` order: offset and facing name.
  @directions List.to_tuple([
                {{0, -1, 0}, "down"},
                {{0, 1, 0}, "up"},
                {{0, 0, -1}, "north"},
                {{0, 0, 1}, "south"},
                {{-1, 0, 0}, "west"},
                {{1, 0, 0}, "east"}
              ])
  @stages ~w(small_amethyst_bud medium_amethyst_bud large_amethyst_bud amethyst_cluster)
  @next Map.new(Enum.zip(@stages, tl(@stages)))
  @water Blocks.id("water")

  @impl true
  def random_tick({x, y, z}, _state, read, random) do
    with 0 <- random.(5),
         {{dx, dy, dz}, facing} = elem(@directions, random.(tuple_size(@directions))),
         target = {x + dx, y + dy, z + dz},
         block when block != nil <- read.(target),
         stage when stage != nil <- next_stage(block, facing) do
      fluid = BlockFacts.fluid(block)

      [
        {:set, target,
         Blocks.state(stage, %{"facing" => facing, "waterlogged" => "#{fluid.kind == :water}"})}
      ]
    else
      _ -> []
    end
  end

  defp next_stage(block, facing) do
    name = Blocks.name(Blocks.block_id(block))

    cond do
      Blocks.class(block) == "AirBlock" ->
        "small_amethyst_bud"

      Blocks.block_id(block) == @water ->
        if BlockFacts.fluid(block).amount == 8, do: "small_amethyst_bud"

      Map.has_key?(@next, name) ->
        if List.keyfind(Blocks.properties(block), "facing", 0) == {"facing", facing},
          do: @next[name]

      true ->
        nil
    end
  end
end
