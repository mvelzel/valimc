defmodule Valimc.World.WeatherReplication do
  @moduledoc "Shared immutable weather event payloads and bounded observer reconciliation."
  alias Valimc.Protocol.Packets
  alias Valimc.World.Weather

  def cache(weather, previous \\ nil) do
    values =
      Map.take(weather, [:rain_level, :thunder_level]) |> Map.put(:wet, Weather.wet?(weather))

    if previous != nil and Map.take(previous, [:rain_level, :thunder_level, :wet]) == values do
      previous
    else
      Map.merge(values, %{
        rain_packet: event(7, weather.rain_level),
        thunder_packet: event(8, weather.thunder_level),
        toggle_packet: event(if(values.wet, do: 1, else: 2), 0.0)
      })
    end
  end

  def reconcile(nil, view),
    do: {view, [view.toggle_packet, view.rain_packet, view.thunder_packet]}

  def reconcile(before, view) do
    packets = if before.rain_level != view.rain_level, do: [view.rain_packet], else: []

    packets =
      if before.thunder_level != view.thunder_level,
        do: packets ++ [view.thunder_packet],
        else: packets

    packets =
      if before.wet != view.wet,
        do: packets ++ [view.toggle_packet, view.rain_packet, view.thunder_packet],
        else: packets

    {view, packets}
  end

  defp event(type, value), do: Packets.packet("game_event", <<type, value::float-32>>)
end
