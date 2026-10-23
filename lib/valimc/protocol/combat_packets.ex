defmodule Valimc.Protocol.CombatPackets do
  @moduledoc """
  The sounds and particles combat sends (VMC-037n): `ClientboundSoundPacket`
  of a sound event at a position and `ClientboundLevelParticlesPacket` of a
  simple particle, with the sound event, sound source and particle type ids
  `CombatOracle` extracts.
  """
  use Valimc.Data.Facts, "registry/combat_facts.json"
  alias Valimc.Protocol.{Packets, Wire}

  @sounds @facts["sounds"]
  @sources @facts["sound_sources"]
  @particles @facts["particles"]

  @doc "A sound source's ordinal (`\"block\"`, `\"record\"`, ...)."
  def source(name), do: Map.fetch!(@sources, name)

  @doc """
  A sound (`ServerLevel.playSeededSound`): event `name` from `source`
  (`"player"`, `"hostile"`, ... or its ordinal) at `{x, y, z}` with
  `volume`, `pitch` and the client's random `seed`.
  """
  def sound(name, source, {x, y, z}, volume, pitch, seed) do
    Packets.packet("sound", [
      Wire.varint(if(is_integer(name), do: name, else: Map.fetch!(@sounds, name)) + 1),
      Wire.varint(if(is_integer(source), do: source, else: Map.fetch!(@sources, source))),
      <<trunc(x * 8.0)::signed-32, trunc(y * 8.0)::signed-32, trunc(z * 8.0)::signed-32,
        volume::float-32, pitch::float-32, seed::signed-64>>
    ])
  end

  @doc """
  Particles (`ServerLevel.sendParticles`): `count` of simple particle `name`
  at `{x, y, z}`, spread by `{dx, dy, dz}` (with no count, the direction),
  at `speed`.
  """
  def particles(name, {x, y, z}, {dx, dy, dz}, speed, count) do
    Packets.packet("level_particles", [
      Wire.varint(Map.fetch!(@particles, name)),
      <<0, 0, x::float-64, y::float-64, z::float-64, dx::float-32, dy::float-32, dz::float-32,
        speed::float-32, speed::float-32, speed::float-32>>,
      Wire.varint(count),
      <<0>>
    ])
  end

  @doc "The network id of particle type `name`."
  def particle_id(name), do: Map.fetch!(@particles, name)

  @doc "A modelled mob type's hurt and death sounds and sound source."
  def mob_sounds(type), do: Map.fetch!(@facts["mobs"], type)
end
