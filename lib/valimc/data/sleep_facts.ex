defmodule Valimc.Data.SleepFacts do
  @moduledoc """
  What beds, sleep and respawn points read beyond the block facts
  (`priv/physics/sleep.json`, `SleepOracle facts`, VMC-040a): each
  dimension's bed rules and whether respawn anchors work there, each bed's
  rule and sleep heights, the entity types that keep a player from resting,
  and per block state the inputs of vanilla's stand-up search
  (`DismountHelper`): whether it suffocates, is dangerous to a player or is
  `invalid_spawn_inside`, and the top of its non-climbable collision shape.
  """
  use Valimc.Data.Facts, "physics/sleep.json"
  import Bitwise

  @rule fn r ->
    %{
      can_sleep: String.to_atom(r["can_sleep"]),
      can_set_spawn: String.to_atom(r["can_set_spawn"]),
      destroy_on_use: r["destroy_on_use"],
      destroy_on_leave: r["destroy_on_leave"],
      error: r["error"]
    }
  end

  @dimensions Map.new(@facts["dimensions"], fn {"minecraft:" <> name, d} ->
                {name,
                 %{
                   bed_rule: @rule.(d["bed_rule"]),
                   straw_bed_rule: @rule.(d["straw_bed_rule"]),
                   respawn_anchor_works: d["respawn_anchor_works"],
                   fixed_time: d["fixed_time"]
                 }}
              end)

  @beds Map.new(@facts["beds"], fn {"minecraft:" <> name, b} ->
          {name,
           %{
             rule: String.to_atom(b["rule"]),
             explodes: b["explodes"],
             foot_height: b["foot_height"],
             head_height: b["head_height"],
             head_needs_foot: b["head_needs_foot"]
           }}
        end)

  @rest MapSet.new(@facts["rest_preventing"])
  @angry MapSet.new(@facts["rest_preventing_when_angry"])
  @flags Base.decode16!(@facts["flags"], case: :lower)
  @floor_states Base.decode16!(@facts["floor_states"], case: :lower)
  @floors List.to_tuple(@facts["floors"])

  unless byte_size(@flags) == Valimc.Data.Blocks.state_count() and
           byte_size(@floor_states) == Valimc.Data.Blocks.state_count(),
         do: raise("Sleep facts do not cover every block state")

  @doc "The rules of `dimension` (an atom such as `:overworld`)."
  def dimension(dimension), do: Map.fetch!(@dimensions, Atom.to_string(dimension))

  @doc "The bed facts of block `name` (without namespace), or nil when it is no bed."
  def bed(name), do: Map.get(@beds, name)

  @doc "The rule a bed of block `name` follows in `dimension`."
  def bed_rule(name, dimension), do: Map.fetch!(dimension(dimension), bed(name).rule)

  @doc "Whether entities of `type` (`\"minecraft:...\"`) keep a player from resting."
  def rest_preventing?(type), do: MapSet.member?(@rest, type)

  @doc "Whether entities of `type` keep a player from resting when angry at it."
  def rest_preventing_when_angry?(type), do: MapSet.member?(@angry, type)

  @doc "Whether `state` suffocates (`isSuffocating`): a player is not free there."
  def suffocating?(state), do: (:binary.at(@flags, state) &&& 1) != 0

  @doc "Whether `state` is dangerous to stand in for a player (`isBlockDangerous`)."
  def dangerous?(state), do: (:binary.at(@flags, state) &&& 2) != 0

  @doc "Whether a player may not respawn inside `state` (`invalid_spawn_inside`)."
  def invalid_inside?(state), do: (:binary.at(@flags, state) &&& 4) != 0

  @doc "The top of `state`'s non-climbable collision shape, nil when it has none."
  def floor(state), do: elem(@floors, :binary.at(@floor_states, state))

  @doc """
  What standing up from a bed reads, for the native mobs (VMC-081d):
  `{flags, floor_states, floors, beds}` (the per-state binaries, the
  floors, the bed blocks' names).
  """
  def native, do: {@flags, @floor_states, Tuple.to_list(@floors), Map.keys(@beds)}
end
