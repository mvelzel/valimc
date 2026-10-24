defmodule Valimc.AI.Dragon.Facts do
  @moduledoc "The dragon's generated arena graph, part dimensions and phase profiles."
  use Valimc.Data.Facts, "registry/dragon_facts.json"

  @graph @facts["graph"] |> Enum.map(fn row -> row |> Enum.map(&trunc/1) |> List.to_tuple() end)
  @parts @facts["parts"] |> Enum.map(&{&1["name"], &1["width"], &1["height"]})
  @phases @facts["phases"]
          |> Map.new(
            &{&1["id"],
             %{speed: &1["speed"], sitting: &1["sitting"], landing: &1["name"] == "Landing"}}
          )

  def ambient_interval, do: @facts["ambient_interval"]
  def max_head_y_rot, do: @facts["max_head_y_rot"]
  def graph, do: @graph
  def parts, do: @parts
  def phase(id), do: Map.fetch!(@phases, id)
end
