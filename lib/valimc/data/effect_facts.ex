defmodule Valimc.Data.EffectFacts do
  @moduledoc """
  Each built-in status effect's static facts (`EffectMetadata`,
  `priv/protocol/effect_facts.json`), by registry id: its category and
  colour, whether it is instantaneous, its particle (`entity_effect`, tinted
  by the colour, or its own), its blend durations and the sound it plays when
  added (`{name, sound id}` or nil).
  """
  use Valimc.Data.Facts, "protocol/effect_facts.json"
  alias Valimc.Data.EffectTypes

  @effects @facts["effects"]
           |> Enum.with_index()
           |> Enum.map(fn {effect, id} ->
             unless EffectTypes.name(id) == effect["name"], do: raise("Wrong effect order")

             %{
               category: String.to_atom(effect["category"]),
               color: effect["color"],
               instantaneous: effect["instantaneous"],
               tinted: effect["particle"] == "minecraft:entity_effect",
               particle: effect["particle_id"],
               blend: List.to_tuple(effect["blend"]),
               sound: effect["sound_on_added"] && List.to_tuple(effect["sound_on_added"])
             }
           end)
           |> List.to_tuple()

  def get(id) when is_integer(id) and id >= 0 and id < tuple_size(@effects),
    do: elem(@effects, id)
end
