defmodule Valimc.Protocol.BossPackets do
  @moduledoc "Vanilla boss-event operations (VMC-045a6); a UUID identifies one bar."
  alias Valimc.Protocol.{Packets, Wire}

  def add(uuid, name, progress, color \\ 0, overlay \\ 0, flags \\ 6),
    do:
      packet(uuid, 0, [
        component(name),
        <<progress::float-32>>,
        Wire.varint(color),
        Wire.varint(overlay),
        <<flags>>
      ])

  def remove(uuid), do: packet(uuid, 1, [])
  def progress(uuid, value), do: packet(uuid, 2, <<value::float-32>>)
  def name(uuid, name), do: packet(uuid, 3, component(name))
  def style(uuid, color, overlay), do: packet(uuid, 4, [Wire.varint(color), Wire.varint(overlay)])
  def flags(uuid, flags), do: packet(uuid, 5, <<flags>>)

  defp packet(<<_::128>> = uuid, operation, body),
    do: Packets.packet("boss_event", [uuid, Wire.varint(operation), body])

  # Native trusted components compact an unstyled literal to a string tag.
  defp component({:compound, %{"text" => {:string, text}} = fields}) when map_size(fields) == 1,
    do: Wire.text_component({:string, text})

  defp component(text) when is_binary(text), do: Wire.text_component({:string, text})
  defp component(tag), do: Wire.text_component(tag)
end
