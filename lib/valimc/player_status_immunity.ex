defmodule Valimc.PlayerStatusImmunity do
  @moduledoc "Source immunity from the validated player effect map; clocks and damage ownership are separate."
  alias Valimc.Protocol.EffectTypes
  @path Path.expand("../../priv/protocol/status_damage.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @fire_sources Enum.map(@facts["fire_resistance_sources"], &String.to_atom/1)
  @fire_resistance EffectTypes.id("fire_resistance")
  unless Valimc.Version.stamped?(@facts) and
           length(@fire_sources) == 8,
         do: raise("Wrong native status immunity reference")

  # Native hasEffect tests map presence, including a zero-duration entry until
  # the effect clock removes it. Amplifier and suppressed rungs do not affect immunity.
  def immune?(effects, source) when is_map(effects) and source in @fire_sources,
    do: Map.has_key?(effects, @fire_resistance)

  def immune?(effects, _source) when is_map(effects), do: false
end
