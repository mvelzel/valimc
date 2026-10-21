defmodule Valimc.Command.Facts do
  @moduledoc """
  The generated command facts (`priv/commands/facts.json`, from the pinned
  server): one decode for every reader (VMC-077o). Server version, time
  markers and timelines, structures and their tags, particle types and the
  item component and predicate ids.
  """
  @path Path.expand("../../../priv/commands/facts.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  unless Valimc.Version.stamped?(@facts),
    do: raise("Command facts are not from the pinned release")

  @particles Map.new(@facts["particles"], &{&1["id"], &1})
  @structures MapSet.new(@facts["structures"])
  @item_components MapSet.new(@facts["item_components"])
  @item_predicates MapSet.new(@facts["item_predicates"])

  def server_version, do: @facts["server_version"]
  def time_markers, do: @facts["time_markers"]
  def timelines, do: @facts["timelines"]
  def structures, do: @structures
  def structure_tags, do: @facts["structure_tags"]
  def particle(id), do: Map.get(@particles, id)
  def item_component?(id), do: MapSet.member?(@item_components, id)
  def item_predicate?(id), do: MapSet.member?(@item_predicates, id)
end
