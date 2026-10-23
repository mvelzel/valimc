defmodule Valimc.Blocks.Transformers do
  @moduledoc """
  Tools' block transformers (VMC-039a, `BlockTransformer.transformBlock`):
  hoes till, shovels flatten paths, axes strip, scrape and unwax. The block
  rules apply an entry (`valimc_core::rules::transform`); this module says
  which items carry a transformer (by default; `priv/physics/
  block_transformers.json`, from GrowthOracle) and what an applied entry does
  beyond the block: its sound, particles (a level event), and the item's
  wear or use.

  Not modelled: an entry's loot (rooted dirt's hanging roots), which comes
  from a block-interaction loot table the loot facts do not hold yet.
  """
  use Valimc.Data.Facts, "physics/block_transformers.json"

  # The rules number the transformers in the facts' order.
  @names @facts["transformers"] |> Map.keys() |> Enum.sort()

  @tools for {item, name} <- @facts["items"],
             into: %{},
             do: {Valimc.Protocol.ItemTypes.id(item), Enum.find_index(@names, &(&1 == name))}

  @entries (for name <- @names do
              for entry <- @facts["transformers"][name] do
                %{
                  sound: entry["sound"],
                  particle: entry["particle"],
                  consume: entry["consume"],
                  damage: entry["damage"]
                }
              end
              |> List.to_tuple()
            end)
           |> List.to_tuple()

  @doc "The transformer an item stack carries (its index), or nil."
  def tool(%{item_id: id}), do: Map.get(@tools, id)
  def tool(_), do: nil

  @doc "Entry `index` of transformer `tool`: its sound, particle, consumption and damage."
  def entry(tool, index), do: @entries |> elem(tool) |> elem(index)
end
