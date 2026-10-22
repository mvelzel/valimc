defmodule Valimc.PlayerRainQuery do
  @moduledoc """
  Rain at a player's feet and head (vanilla `isRainingAt`), read from the same
  block view as its movement (VMC-077e): the column's MOTION_BLOCKING height
  and lowest sky source and the biomes its owner publishes beside its
  snapshot, and each point's precipitation (`Valimc.World.Climate`). No owner
  call, no revision fence.
  """
  alias Valimc.Physics.RainContact
  alias Valimc.World.{Climate, Clock, View}

  @doc "Rain at the feet of a body at `{x, y, z}` and its head at height `top`."
  def sample({x, y, z}, top, %View{} = view) do
    if Clock.weather().wet do
      {x, z} = {floor(x), floor(z)}
      feet = {x, floor(y), z}
      head = {x, floor(top), z}

      with {:ok, heights} <- View.column(view, x, z),
           {:ok, feet_precipitation} <- precipitation(view, feet),
           {:ok, head_precipitation} <- precipitation(view, head) do
        RainContact.exposed?(
          true,
          heights.motion_blocking,
          {elem(feet, 1), elem(feet, 1) >= heights.sky_source, feet_precipitation},
          {elem(head, 1), elem(head, 1) >= heights.sky_source, head_precipitation}
        )
      else
        :error -> {:error, :rain_column_unavailable}
      end
    else
      {:ok, false}
    end
  end

  defp precipitation(view, position) do
    with {:ok, biome} <- View.biome(view, position),
         do: {:ok, Climate.precipitation(biome, position, sea_level())}
  end

  # The snow line follows the generator's sea level; the overworld's is 63, as
  # vanilla's login tells clients.
  defp sea_level do
    case Valimc.Dimension.current() do
      :overworld -> 63
      dimension -> Valimc.Dimension.facts(dimension).sea_level
    end
  end
end
