defmodule Valimc.Entity.ContainerScatter do
  @moduledoc "Native stored-stack splitting and launch from explicit RNG draws; UUIDs, component copies and durability belong to the owner proposal."
  @spread 0.11485000171139836

  def plan({x, y, z}, count, {a, b, c}, piles)
      when is_number(x) and is_number(y) and is_number(z) and is_integer(count) and
             count in 0..99 and is_list(piles) do
    if abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and y >= -64 and y < 320 and
         uniform?(a) and uniform?(b) and uniform?(c) do
      position =
        {floor(x) + a * 0.75 + 0.125, floor(y) + b * 0.75, floor(z) + c * 0.75 + 0.125}

      split(count, position, piles, [])
    else
      {:error, :invalid_container_scatter}
    end
  end

  def plan(_, _, _, _), do: {:error, :invalid_container_scatter}

  defp split(0, _, [], records), do: {:ok, Enum.reverse(records)}

  defp split(remaining, position, [{size, {a, b, c, d, e, f}} | draws], records)
       when remaining > 0 and is_integer(size) and size in 0..20 do
    if uniform?(a) and uniform?(b) and uniform?(c) and uniform?(d) and uniform?(e) and uniform?(f) do
      count = min(remaining, size + 10)

      record = %{
        count: count,
        position: position,
        pickup_delay: 0,
        velocity: {0.0 + @spread * (a - b), 0.2 + @spread * (c - d), 0.0 + @spread * (e - f)}
      }

      split(remaining - count, position, draws, [record | records])
    else
      {:error, :invalid_container_scatter}
    end
  end

  defp split(_, _, _, _), do: {:error, :invalid_container_scatter}
  defp uniform?(value), do: is_number(value) and value >= 0 and value < 1
end
