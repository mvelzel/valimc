defmodule Valimc.Data.BucketFacts do
  @moduledoc "Generated native bucket types and variant names/wire ids (VMC-043e8)."
  use Valimc.Data.Facts, "registry/bucket_facts.json"

  @enums Map.new(@facts["components"], fn {name, table} ->
           {name, Map.new(@facts["enums"][table], fn [id, value] -> {id, value} end)}
         end)
  def types, do: @facts["types"]
  def enums, do: @enums
  def enum(name), do: @enums[name]
end
