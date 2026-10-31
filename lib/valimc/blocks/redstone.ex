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
  alias Valimc.Data.{Blocks, Float32}
  alias Valimc.Protocol.{CombatPackets, Packets, Wire}

  @sounds @facts["components"]
          |> Enum.flat_map(&Map.get(&1, "sounds", []))
          |> Enum.uniq()
          |> List.to_tuple()

  @usable_kinds ~w(lever button door trapdoor gate note daylight repeater comparator)
  @usable for %{"block" => block, "kind" => kind} <- @facts["components"],
              kind in @usable_kinds,
              state <- Blocks.states(block),
              into: MapSet.new(),
              do: state

  @placed_by MapSet.new(
               Enum.flat_map(
                 ~w(tripwire_hook repeater comparator piston sticky_piston),
                 &Enum.to_list(Blocks.states(&1))
               )
             )
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

  @doc """
  Whether placing `state` runs its `setPlacedBy`: a tripwire hook calculates
  its line, a diode checks its input (VMC-048a), a piston whether to extend
  (VMC-048b).
  """
  def placed_by?(state), do: MapSet.member?(@placed_by, state)

  @doc "The daylight detector states, whose block entities tick."
  def detectors, do: @detectors

  @doc "Whether a tick of `state`'s block checks the entities on it (plates, buttons, tripwire)."
  def checks?(state), do: MapSet.member?(@checks, state)

  @doc "The states whose blocks an entity standing in them reaches (`checks?/1`)."
  def contact_states, do: MapSet.to_list(@checks)

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
  A container's analog signal (`AbstractContainerMenu.getRedstoneSignalFromContainer`,
  VMC-048a): its fullness, each stack's count over its maximum (at most 99),
  averaged over its `size` slots and spread over 1..15, in vanilla's float
  arithmetic. `stacks` are the slots (`nil` empty), as `ItemStack`s or
  `{item name, count}`.
  """
  def container_signal(stacks, size) do
    total =
      Enum.reduce(stacks, 0.0, fn
        nil, acc ->
          acc

        {name, count}, acc ->
          add_fullness(acc, count, Valimc.Protocol.ItemStack.new(name, count))

        %Valimc.Protocol.ItemStack{count: count} = stack, acc ->
          add_fullness(acc, count, stack)
      end)

    fullness = Float32.round(total / size)
    # `Mth.lerpDiscrete(fullness, 0, 15)`.
    floor(Float32.round(fullness * 14)) + if(fullness > 0, do: 1, else: 0)
  end

  @doc """
  The analog signal of an owned container entry (VMC-048a): a chest's 27
  slots, a furnace's 3.
  """
  def entry_signal(%{rows: rows, slots: slots}),
    do: container_signal(Tuple.to_list(slots), rows * 9)

  def entry_signal(%{cooking: %{slots: slots}}),
    do: container_signal(Tuple.to_list(slots), tuple_size(slots))

  # A brewing stand's five (VMC-034o).
  def entry_signal(%{brewing: %{slots: slots}}),
    do: container_signal(Tuple.to_list(slots), tuple_size(slots))

  # Hoppers, droppers and dispensers (VMC-049a).
  def entry_signal(%{kind: _, slots: slots}),
    do: container_signal(Tuple.to_list(slots), tuple_size(slots))

  def entry_signal(_), do: 0

  defp add_fullness(acc, count, stack) do
    max = min(99, Valimc.Protocol.ItemStack.max_stack_size(stack))
    Float32.round(acc + Float32.round(count / max))
  end

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
          do: Float32.round(:math.pow(2.0, (String.to_integer(props["note"]) - 12) / 12.0)),
          else: 1.0

      {instrument["sound"], pitch}
    else
      _ -> nil
    end
  end
end
