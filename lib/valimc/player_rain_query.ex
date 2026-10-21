defmodule Valimc.PlayerRainQuery do
  @moduledoc """
  Rain at a player's feet and head (vanilla `isRainingAt`), read from the same
  block view as its movement (VMC-077e): no owner call, no revision fence.
  """
  alias Valimc.Physics.RainContact
  alias Valimc.Registry.BlockFacts
  alias Valimc.World.{Clock, FlatClimate, View}

  def sample({x, y, z}, %{box: {_, _, _, _, top, _}}, %View{} = view) do
    if Clock.weather().wet do
      {x, z} = {floor(x), floor(z)}
      feet = {x, floor(y), z}
      head = {x, floor(top), z}

      with {:ok, heights} <- heights(view, x, z),
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

  @doc """
  A column's MOTION_BLOCKING height and lowest sky source
  (`ChunkSkyLightSources`: one above the top edge vertical sky light cannot
  pass), scanned from the top down; the build minimum when there is none.
  """
  def heights(view, x, z), do: column(view, x, z, 319, View.fetch(view, {x, 320, z}), nil, nil)

  defp column(_view, _x, _z, y, _above, motion, sky)
       when (motion != nil and sky != nil) or y < -64,
       do: {:ok, %{motion_blocking: motion || -64, sky_source: sky || -64}}

  defp column(view, x, z, y, {:ok, above}, motion, sky) do
    case View.fetch(view, {x, y, z}) do
      {:ok, state} ->
        motion = motion || if(BlockFacts.heightmap?(state, :motion_blocking), do: y + 1)
        sky = sky || if(BlockFacts.sky_blocked?(above, state), do: y + 1)
        column(view, x, z, y - 1, {:ok, state}, motion, sky)

      :error ->
        {:error, :rain_column_unavailable}
    end
  end

  defp column(_view, _x, _z, _y, :error, _motion, _sky), do: {:error, :rain_column_unavailable}
end
