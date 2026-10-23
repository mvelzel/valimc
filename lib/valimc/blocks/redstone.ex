defmodule Valimc.Blocks.Redstone do
  @moduledoc """
  Redstone's components as the region owner meets them (VMC-047a). The Rust
  rules (`valimc_core::rules::power` and `components`) read
  `priv/physics/redstone.json` themselves (`RedstoneOracle facts`) and run
  every reaction; this module keeps what the owner starts them with and
  plays from them: the blocks a player's use reaches, the states whose
  block entities tick (daylight detectors), the sounds a run names by index
  (first appearance over the components, as the rules number them) and a
  note block's sound.
  """
  use Valimc.Data.Facts, "physics/redstone.json"
  import Bitwise, only: [<<<: 2]
  alias Valimc.Data.Blocks
  alias Valimc.Protocol.{CombatPackets, Packets, Wire}

  @sounds @facts["components"]
          |> Enum.flat_map(&Map.get(&1, "sounds", []))
          |> Enum.uniq()
          |> List.to_tuple()

  @usable_kinds ~w(lever button door trapdoor gate note daylight)
  @usable for %{"block" => block, "kind" => kind} <- @facts["components"],
              kind in @usable_kinds,
              state <- Blocks.states(block),
              into: MapSet.new(),
              do: state

  @hooks MapSet.new(Blocks.states("tripwire_hook"))
  @checks for %{"block" => block, "kind" => kind} <- @facts["components"],
              kind in ~w(button plate weighted tripwire),
              state <- Blocks.states(block),
              into: MapSet.new(),
              do: state
  @detectors Enum.to_list(Blocks.states("daylight_detector"))
  @note_block Blocks.id("note_block")
  @instruments Map.new(@facts["instruments"], &{&1["name"], &1})

  @sound_ids @facts["sound_ids"]

  @doc "The sound a run's index names (`minecraft:block.lever.click`)."
  def sound(index), do: elem(@sounds, index)

  @doc """
  The sound packet (`ClientboundSoundPacket`) of registered sound `name` from
  `source` (`"block"`, `"record"`) at `{x, y, z}` with `volume` and `pitch`.
  """
  def sound_packet(name, source, {x, y, z}, volume, pitch) do
    Packets.packet("sound", [
      Wire.varint(Map.fetch!(@sound_ids, name) + 1),
      Wire.varint(CombatPackets.source(source)),
      <<trunc(x * 8.0)::signed-32, trunc(y * 8.0)::signed-32, trunc(z * 8.0)::signed-32,
        volume::float-32, pitch::float-32, :rand.uniform(1 <<< 62)::signed-64>>
    ])
  end

  @doc "The sounds in the rules' order."
  def sounds, do: Tuple.to_list(@sounds)

  @doc "Whether a player's use of `state` reaches the rules (`useWithoutItem`)."
  def usable?(state), do: MapSet.member?(@usable, state)

  @doc "Whether `state` is a tripwire hook (its placement calculates its line)."
  def hook?(state), do: MapSet.member?(@hooks, state)

  @doc "The daylight detector states, whose block entities tick."
  def detectors, do: @detectors

  @doc "Whether a tick of `state`'s block checks the entities on it (plates, buttons, tripwire)."
  def checks?(state), do: MapSet.member?(@checks, state)

  @doc """
  What redstone's contacts and checks see of a stored entity: its box and
  kind (`:living` for mobs, `:other` for items, orbs and objects).
  """
  def entity_box(%{kind: :item, entity: %{x: x, y: y, z: z}}),
    do: {{x - 0.125, y, z - 0.125}, {x + 0.125, y + 0.25, z + 0.125}, :other}

  def entity_box(%{kind: :orb, entity: %{x: x, y: y, z: z}}),
    do: {{x - 0.25, y, z - 0.25}, {x + 0.25, y + 0.5, z + 0.25}, :other}

  def entity_box(%{kind: kind, body: %{type: type}, entity: %{x: x, y: y, z: z}})
      when kind in [:mob, :object] do
    facts = Valimc.Data.EntityTypes.fetch(type)
    half = facts.width / 2

    {{x - half, y, z - half}, {x + half, y + facts.height, z + half},
     if(kind == :mob, do: :living, else: :other)}
  end

  def entity_box(_), do: nil

  @doc """
  A note block's block event (`NoteBlock.triggerEvent`) at `state`: its
  instrument's sound and pitch (`getPitchFromNote` for a tunable one), or
  nil for a mob head's, which reads the head's block entity.
  """
  def note_sound(state) do
    with true <- Blocks.block_id(state) == @note_block,
         props = Map.new(Blocks.properties(state)),
         %{"custom" => false} = instrument <- @instruments[props["instrument"]] do
      pitch =
        if instrument["tunable"],
          do:
            Valimc.Data.Float32.round(
              :math.pow(2.0, (String.to_integer(props["note"]) - 12) / 12.0)
            ),
          else: 1.0

      {instrument["sound"], pitch}
    else
      _ -> nil
    end
  end
end
