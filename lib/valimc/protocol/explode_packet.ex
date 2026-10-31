defmodule Valimc.Protocol.ExplodePacket do
  @moduledoc """
  Vanilla's `ClientboundExplodePacket` (VMC-050a): the centre, radius, the
  count of cells the rays reached, the knockback of the player it is sent
  to (or none), then the default explosion's particle (small below radius 2
  or without block changes, else the emitter), `GENERIC_EXPLODE` and the
  default block particles, which `ExplosionOracle packet` encodes once, and
  whether the sound plays. The client plays the effects and adds the
  knockback to its own motion.
  """
  use Valimc.Data.Facts, "protocol/explosion_packet.json"
  alias Valimc.Protocol.Data

  @small Base.decode16!(@facts["small"], case: :lower)
  @large Base.decode16!(@facts["large"], case: :lower)
  # A wind burst's gusts and the breeze's burst, without block particles.
  @wind_small Base.decode16!(@facts["wind_small"], case: :lower)
  @wind_large Base.decode16!(@facts["wind_large"], case: :lower)
  unless Data.id(:play, :clientbound, "explode") == @facts["id"],
    do: raise("Explode packet id differs from the oracle's")

  @doc """
  The packet for an explosion at `{x, y, z}` of `radius` whose rays reached
  `count` cells; `knockback` is `{x, y, z}` or nil, `small` picks the small
  particle and `wind` a wind burst's.
  """
  def packet({x, y, z}, radius, count, knockback, small, wind \\ false) do
    knockback =
      case knockback do
        nil -> <<0>>
        {kx, ky, kz} -> <<1, kx * 1.0::float-64, ky * 1.0::float-64, kz * 1.0::float-64>>
      end

    {Data.id(:play, :clientbound, "explode"),
     [
       <<x * 1.0::float-64, y * 1.0::float-64, z * 1.0::float-64, radius * 1.0::float-32,
         count::signed-32>>,
       knockback,
       case {wind, small} do
         {false, true} -> @small
         {false, false} -> @large
         {true, true} -> @wind_small
         {true, false} -> @wind_large
       end,
       <<1>>
     ]}
  end
end
