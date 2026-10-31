defmodule Valimc.Protocol.Particles do
  @moduledoc """
  Every particle type's network id, from the command facts' particle list
  (`CommandTreeOracle`), for the simple particles effects send (VMC-037q:
  an enchantment's `spawn_particles`).
  """
  use Valimc.Data.Facts, "commands/facts.json"
  alias Valimc.Protocol.{Packets, Wire}

  @ids Map.new(@facts["particles"], &{&1["id"], &1["network_id"]})

  @doc "The network id of particle type `name`, or nil."
  def id(name), do: Map.get(@ids, name)

  @doc """
  `ServerLevel.sendParticles` of simple particle `name` with a count of 0:
  one particle moving along `{dx, dy, dz}` at `speed`.
  """
  def moving(name, {x, y, z}, {dx, dy, dz}, speed) do
    Packets.packet("level_particles", [
      Wire.varint(Map.fetch!(@ids, name)),
      <<0, 0, x::float-64, y::float-64, z::float-64, dx::float-32, dy::float-32, dz::float-32,
        speed::float-32, speed::float-32, speed::float-32>>,
      Wire.varint(0),
      <<0>>
    ])
  end
end
