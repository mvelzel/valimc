defmodule Valimc.World.FlatClimate do
  @moduledoc "Plains precipitation for the current sea-level63 generator, including altitude temperature noise."
  import Bitwise
  @path Path.expand("../../../priv/physics/flat_climate.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @permutation Base.decode16!(@facts["permutation"], case: :lower)
  @gradients @facts["gradients"] |> Enum.map(&List.to_tuple/1) |> List.to_tuple()
  @f2 0.5 * (:math.sqrt(3.0) - 1.0)
  @g2 (3.0 - :math.sqrt(3.0)) / 6.0
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           @facts["biome"] == "minecraft:plains" and @facts["sea_level"] == 63 and
           @facts["temperature"] == 0.8 and byte_size(@permutation) == 256 and
           Enum.sort(:binary.bin_to_list(@permutation)) == Enum.to_list(0..255) and
           tuple_size(@gradients) == 12,
         do: raise("Wrong flat-plains climate facts")

  def temperature({x, y, z})
      when is_integer(x) and abs(x) < 30_000_000 and is_integer(z) and abs(z) < 30_000_000 and
             is_integer(y) and abs(y) <= 1_000_000 do
    temperature =
      if y <= 80 do
        f32(0.8)
      else
        noise = f32(noise(f32(f32(x) / 8.0), f32(f32(z) / 8.0)) * 8.0)
        cooling = f32(f32(f32(f32(noise + f32(y)) - 80.0) * f32(0.05)) / 40.0)
        f32(f32(0.8) - cooling)
      end

    {:ok, temperature}
  end

  def temperature(_), do: {:error, :invalid_climate_position}

  def precipitation(position) do
    with {:ok, temperature} <- temperature(position),
         do: {:ok, if(temperature < f32(0.15), do: :snow, else: :rain)}
  end

  # A fixed, immutable permutation supplies three simplex contributions. There
  # is no runtime random generator, cache owner or per-column process.
  defp noise(x, z) do
    skew = (x + z) * @f2
    i = floor(x + skew)
    j = floor(z + skew)
    unskew = (i + j) * @g2
    dx = x - (i - unskew)
    dz = z - (j - unskew)
    {ix, iz} = if dx > dz, do: {1, 0}, else: {0, 1}
    a = contribution(i, j, dx, dz)
    b = contribution(i + ix, j + iz, dx - ix + @g2, dz - iz + @g2)
    c = contribution(i + 1, j + 1, dx - 1.0 + 2.0 * @g2, dz - 1.0 + 2.0 * @g2)
    f32(70.0 * (a + b + c))
  end

  defp contribution(i, j, x, z) do
    radius = 0.5 - x * x - z * z

    if radius < 0.0 do
      0.0
    else
      {gx, gz} = elem(@gradients, rem(permute(i + permute(j)), 12))
      squared = radius * radius
      squared * squared * (gx * x + gz * z)
    end
  end

  defp permute(i), do: :binary.at(@permutation, i &&& 255)

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
