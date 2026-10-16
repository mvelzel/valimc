defmodule Valimc.PlayerRainQuery do
  @moduledoc "One fenced column read inside the existing geometry worker; no vertical block scan."
  alias Valimc.Physics.{BlockCollisions.Frame, RainContact}
  alias Valimc.World
  alias Valimc.World.{Clock, FlatClimate, Region}

  def sample({x, y, z}, %{box: {_, _, _, _, top, _}}, %Frame{fences: fences}) do
    if Clock.weather().wet do
      {x, z} = column = {floor(x), floor(z)}
      feet = {x, floor(y), z}
      head = {x, floor(top), z}
      key = World.region_key(World.chunk_key(x, z))

      with {:ok, %{owner: owner, revision: revision}} <- source(fences, key),
           {:ok, %{owner: ^owner, revision: ^revision, columns: %{^column => heights}}} <-
             Region.observe_columns(owner, [column], revision),
           {:ok, feet_precipitation} <- FlatClimate.precipitation(feet),
           {:ok, head_precipitation} <- FlatClimate.precipitation(head) do
        RainContact.exposed?(
          true,
          heights.motion_blocking,
          {elem(feet, 1), elem(feet, 1) >= heights.sky_source, feet_precipitation},
          {elem(head, 1), elem(head, 1) >= heights.sky_source, head_precipitation}
        )
      end
    else
      {:ok, false}
    end
  end

  defp source(fences, key) do
    case Map.fetch(fences, key) do
      {:ok, fence} -> {:ok, fence}
      :error -> {:error, :rain_source_unavailable}
    end
  end
end
