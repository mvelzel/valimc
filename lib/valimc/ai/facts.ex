defmodule Valimc.AI.Facts do
  @moduledoc """
  What the AI reads of vanilla (`MobAiOracle facts`, `ai_facts.json`):
  `Mth.atan2`'s tables, each block state's path type
  (`WalkNodeEvaluator.getPathTypeFromState`) and the path types' default
  malus, the items whose `mob_visibility` hides their wearer from some
  types, and per modelled mob its head limits, ambient sound and interval,
  malus overrides and the goals vanilla registers (which `Valimc.AI.Mobs`
  must list as they are).
  """
  use Valimc.Data.Facts, "registry/ai_facts.json"

  double = fn hex ->
    <<v::float-64>> = Base.decode16!(hex, case: :lower)
    v
  end

  @asin @facts["atan2"]["asin"] |> Enum.map(double) |> List.to_tuple()
  @cos @facts["atan2"]["cos"] |> Enum.map(double) |> List.to_tuple()

  @doc false
  def atan2_table(:asin), do: @asin
  def atan2_table(:cos), do: @cos

  @path_types @facts["path_types"] |> Enum.map(&String.to_atom(&1["name"])) |> List.to_tuple()
  @malus Map.new(@facts["path_types"], &{String.to_atom(&1["name"]), &1["malus"] * 1.0})
  @path_states Base.decode16!(@facts["path_type_states"], case: :lower)

  unless byte_size(@path_states) == Valimc.Data.Blocks.state_count(),
    do: raise("AI facts and the block registry differ in state count")

  @doc "The path type of block `state` alone (`getPathTypeFromState`)."
  def path_type(state), do: elem(@path_types, :binary.at(@path_states, state))

  goal = fn [priority, name, flags] -> {priority, name, Enum.map(flags, &String.to_atom/1)} end

  @mobs Map.new(@facts["mobs"], fn {name, row} ->
          {name,
           %{
             max_head_y_rot: row["max_head_y_rot"] * 1.0,
             max_head_x_rot: row["max_head_x_rot"] * 1.0,
             head_rot_speed: row["head_rot_speed"] * 1.0,
             ambient_sound: row["ambient_sound"],
             ambient_interval: row["ambient_sound_interval"],
             volume: row["sound_volume"] * 1.0,
             malus:
               Map.merge(
                 @malus,
                 Map.new(row["malus"], fn {k, v} -> {String.to_atom(k), v * 1.0} end)
               ),
             goals: Enum.map(row["goals"], goal),
             targets: Enum.map(row["targets"], goal)
           }}
        end)

  @doc "The AI facts of mob type `type`, or nil for a type without AI facts."
  def mob(type), do: @mobs[type]

  @doc "The types with AI facts."
  def mobs, do: Map.keys(@mobs)

  @visibility Map.new(@facts["mob_visibility"], fn {item, row} ->
                {item,
                 %{
                   visibility: row["visibility"] * 1.0,
                   slot: String.to_atom(row["slot"]),
                   types: row["types"]
                 }}
              end)

  @doc "The `mob_visibility` of item `name` worn in its equippable slot, or nil."
  def visibility(name), do: @visibility[name]

  @doc "The protocol id of sound event `name` the AI plays."
  def sound_id(name), do: Map.fetch!(@facts["sounds"], name)

  @swing Base.decode16!(@facts["swing_fields"], case: :lower)

  @doc """
  `ClientboundSwingAnimationPacket`'s fields after the entity id for a
  main-hand swing of the default animation (an empty hand's).
  """
  def swing_fields, do: @swing
end
