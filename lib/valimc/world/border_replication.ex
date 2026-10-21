defmodule Valimc.World.BorderReplication do
  @moduledoc """
  World border packets (VMC-027b): the full state when a player enters a
  dimension (`ClientboundInitializeBorderPacket`), then the packet vanilla's
  border listener sends for each kind of change since the player's last view.
  Packets are built from the state at observation time, so a moving border's
  remaining ticks are current.
  """
  alias Valimc.Protocol.{Packets, Wire}
  alias Valimc.World.Border

  def initialize(%Border{} = border) do
    Packets.packet("initialize_border", [
      <<border.center_x::float-64, border.center_z::float-64, Border.size(border)::float-64,
        Border.lerp_target(border)::float-64>>,
      Wire.varlong(Border.lerp_time(border)),
      Wire.varint(border.absolute_max),
      Wire.varint(border.warning_blocks),
      Wire.varint(border.warning_time)
    ])
  end

  def center(border),
    do:
      Packets.packet(
        "set_border_center",
        <<border.center_x::float-64, border.center_z::float-64>>
      )

  def size(border),
    do: Packets.packet("set_border_size", <<Border.lerp_target(border)::float-64>>)

  def lerp_size(border),
    do:
      Packets.packet("set_border_lerp_size", [
        <<Border.size(border)::float-64, Border.lerp_target(border)::float-64>>,
        Wire.varlong(Border.lerp_time(border))
      ])

  def warning_delay(border),
    do: Packets.packet("set_border_warning_delay", Wire.varint(border.warning_time))

  def warning_distance(border),
    do: Packets.packet("set_border_warning_distance", Wire.varint(border.warning_blocks))

  @doc "The observer's new view and the packets that bring it up to date."
  def reconcile(nil, border), do: {border, [initialize(border)]}

  def reconcile(%Border{revisions: same}, %Border{revisions: same} = border), do: {border, []}

  def reconcile(%Border{revisions: before}, %Border{revisions: now} = border) do
    packets =
      for {kind, encode} <- [
            center: &center/1,
            size: if(border.size_change == :lerp, do: &lerp_size/1, else: &size/1),
            warning_time: &warning_delay/1,
            warning_blocks: &warning_distance/1
          ],
          before[kind] != now[kind],
          do: encode.(border)

    {border, packets}
  end
end
