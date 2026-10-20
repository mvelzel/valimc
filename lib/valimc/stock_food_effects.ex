defmodule Valimc.StockFoodEffects do
  @moduledoc "Pinned stock food callback groups; resolution is pure and the player owner supplies draws."
  alias Valimc.FoodItems
  alias Valimc.Protocol.ItemStack
  @path Path.expand("../../priv/protocol/consume_status.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  unless Valimc.Version.stamped?(@facts, ~w(version protocol server_sha1)),
    do: raise("stock food effects do not match the supported protocol")

  @items Map.new(@facts["items"], fn item ->
           callbacks =
             Enum.map(item["callbacks"], fn callback ->
               effects =
                 Enum.map(callback["effects"], fn effect ->
                   {effect["id"], [List.to_tuple(effect["rung"])]}
                 end)

               %{probability: callback["probability"], effects: effects}
             end)

           {item["item_id"], callbacks}
         end)

  def policy(%ItemStack{item_id: id}, %{consumable: consumable, other_listeners: []}) do
    if consumable != nil and consumable == FoodItems.defaults(id).consumable and
         Map.has_key?(@items, id),
       do: {:ok, @items[id]},
       else: :unsupported
  end

  def policy(_, _), do: :unsupported

  @doc "One native float draw selects an entire ordered callback group, even if no add would notify."
  def resolve(callbacks, draws) when is_list(callbacks) and is_list(draws) do
    if length(callbacks) == length(draws) and Enum.all?(draws, &valid_draw?/1) do
      effects =
        for {callback, draw} <- Enum.zip(callbacks, draws),
            draw < callback.probability,
            effect <- callback.effects,
            do: effect

      {:ok, effects}
    else
      {:error, :invalid_food_effect_draws}
    end
  end

  def resolve(_, _), do: {:error, :invalid_food_effect_draws}

  defp valid_draw?(draw) when is_number(draw) and draw >= 0 and draw < 1 do
    <<rounded::float-32>> = <<draw::float-32>>
    rounded == draw
  end

  defp valid_draw?(_), do: false
end
