defmodule Valimc.Commands do
  @moduledoc "Immutable catalog of implemented preview commands; no global dispatch process."
  alias Valimc.Protocol.Wire

  @catalog [
    %{name: "help", handler: :help},
    %{name: "stats", handler: :stats},
    %{name: "spawn", handler: :spawn}
  ]
  @count length(@catalog)
  @graph IO.iodata_to_binary([
           Wire.varint(@count + 1),
           <<0>>,
           Wire.varint(@count),
           Enum.map(1..@count, &Wire.varint/1),
           Enum.map(@catalog, fn command ->
             # Literal (1), executable (4), no children/redirect/restriction.
             [<<5, 0>>, Wire.string(command.name)]
           end),
           Wire.varint(0)
         ])

  def catalog, do: @catalog
  def graph_payload, do: @graph

  def help_text,
    do:
      Enum.map_join(@catalog, " · ", &("/" <> &1.name)) <>
        ". Creative preview, no survival simulation yet."

  def resolve(input) do
    # Brigadier literal names are case-sensitive; these commands accept no arguments.
    # Empty argument lists do not consume suffix whitespace in Brigadier.
    case Enum.find(@catalog, &(&1.name == input)) do
      nil -> :unknown
      command -> command.handler
    end
  end
end
