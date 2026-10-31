defmodule Valimc.Blocks.Cauldron do
  @moduledoc """
  Water bottles and cauldrons (VMC-034o, `CauldronInteraction`): a water
  bottle pours a level into an empty or not yet full water cauldron and
  leaves a glass bottle; a glass bottle takes a level back out as a water
  bottle, the last one leaving an empty cauldron. Each sounds `item.bottle.empty`
  or `item.bottle.fill` at the cauldron.
  """
  alias Valimc.Data.{Blocks, PotionTypes}
  alias Valimc.Protocol.{ItemStack, ItemTypes, PotionContents}

  @empty Blocks.default_state("cauldron")
  @water Blocks.states("water_cauldron")
  @potion ItemTypes.id("potion")
  @bottle ItemTypes.id("glass_bottle")
  @water_potion PotionTypes.id("water")

  @doc "What a held stack does to a cauldron: `:pour` (a water bottle), `:fill` (a glass bottle) or nil."
  def use_of(%ItemStack{item_id: @bottle}), do: :fill

  def use_of(%ItemStack{item_id: @potion} = stack),
    do: if(PotionContents.of(stack).potion == @water_potion, do: :pour)

  def use_of(_), do: nil

  @doc "The cauldron after `use`, or `:pass` when it takes none."
  def apply(@empty, :pour), do: {:ok, level(1)}

  def apply(state, :pour) when state in @water do
    case current(state) do
      3 -> :pass
      n -> {:ok, level(n + 1)}
    end
  end

  def apply(state, :fill) when state in @water do
    case current(state) do
      1 -> {:ok, @empty}
      n -> {:ok, level(n - 1)}
    end
  end

  def apply(_state, _use), do: :pass

  @doc "What the hand gets back."
  def result(:pour), do: ItemStack.new("glass_bottle")

  def result(:fill),
    do: %{
      ItemStack.new("potion")
      | components: %{
          "minecraft:potion_contents" => %{PotionContents.empty() | potion: @water_potion}
        }
    }

  @doc "The sound at the cauldron."
  def sound(:pour), do: "minecraft:item.bottle.empty"
  def sound(:fill), do: "minecraft:item.bottle.fill"

  defp level(n), do: Blocks.state("water_cauldron", %{"level" => Integer.to_string(n)})

  defp current(state),
    do: state |> Blocks.properties() |> List.keyfind("level", 0) |> elem(1) |> String.to_integer()
end
