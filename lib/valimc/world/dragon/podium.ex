defmodule Valimc.World.Dragon.Podium do
  @moduledoc "The End's active/inactive exit feature and native drop intent (VMC-045a6)."
  alias Valimc.Data.Blocks

  @air Blocks.default_state("air")
  @bedrock Blocks.default_state("bedrock")
  @stone Blocks.default_state("end_stone")
  @portal Blocks.default_state("end_portal")

  @doc "Ordered feature intents `{cell, state, drop_previous?}`, before owner admission."
  def feature({ox, oy, oz}, active) do
    basin =
      for z <- -4..4,
          y <- -1..32,
          x <- -4..4,
          distance = x * x + y * y + z * z,
          distance < 3.5 * 3.5 do
        inner = distance < 2.5 * 2.5

        {block, drops} =
          cond do
            y < 0 and inner -> {@bedrock, false}
            y < 0 -> {@stone, active}
            y > 0 -> {@air, active}
            not inner -> {@bedrock, false}
            active -> {@portal, true}
            true -> {@air, false}
          end

        {{ox + x, oy + y, oz + z}, block, drops}
      end

    pillar = for y <- 0..3, do: {{ox, oy + y, oz}, @bedrock, false}

    torches =
      for {dx, dz, face} <- [{0, -1, "north"}, {1, 0, "east"}, {0, 1, "south"}, {-1, 0, "west"}],
          do: {{ox + dx, oy + 2, oz + dz}, Blocks.state("wall_torch", %{"facing" => face}), false}

    basin ++ pillar ++ torches
  end

  @doc "Ordered writes and drop intents against a reader, including earlier writes."
  def plan(origin, active, read) do
    {_cells, writes, drops} =
      Enum.reduce(feature(origin, active), {%{}, [], []}, fn {at, block, drop},
                                                             {cells, writes, drops} ->
        old = Map.get_lazy(cells, at, fn -> read.(at) end)

        if drop and old == block do
          {cells, writes, drops}
        else
          {Map.put(cells, at, block), [{at, block} | writes],
           if(drop, do: [{at, old} | drops], else: drops)}
        end
      end)

    {Enum.reverse(writes), Enum.reverse(drops)}
  end

  @doc "Choose the first portal's floor from the no-leaves heightmap and bedrock column."
  def location(height, read, min_y) do
    y = descend(height - 1, read)
    {0, max(min_y + 1, y), 0}
  end

  defp descend(y, read) when y > 63 do
    if read.({0, y, 0}) == @bedrock, do: descend(y - 1, read), else: y
  end

  defp descend(y, _read), do: y
end
