# Canonical NBT digest shared by the world NBT oracle checks (VMC-020/021); the
# Java side is `WorldNbtOracle.digest`: compound keys sorted by UTF-8 bytes,
# strings as UTF-8, raw float bits, list elements each with their own type
# (vanilla unwraps `{"": tag}` compound-list elements on load).
defmodule NbtCanon do
  @ids %{
    byte: 1,
    short: 2,
    int: 3,
    long: 4,
    float: 5,
    double: 6,
    byte_array: 7,
    string: 8,
    list: 9,
    compound: 10,
    int_array: 11,
    long_array: 12
  }
  @widths %{byte_array: 1, int_array: 4, long_array: 8}

  def digest(tag),
    do: :crypto.hash(:sha256, canon(tag)) |> Base.encode16(case: :lower)

  def canon({type, value}), do: [@ids[type], payload(type, value)]

  defp payload(:byte, v), do: <<v::signed-8>>
  defp payload(:short, v), do: <<v::signed-16>>
  defp payload(:int, v), do: <<v::signed-32>>
  defp payload(:long, v), do: <<v::signed-64>>
  defp payload(type, v) when type in [:float, :double], do: v
  defp payload(:string, v), do: [<<byte_size(v)::32>>, v]

  defp payload(type, v) when is_map_key(@widths, type),
    do: [<<div(byte_size(v), @widths[type])::32>>, v]

  defp payload(:list, {type, values}) do
    elements =
      Enum.map(values, fn
        # Vanilla unwraps `{"": tag}` elements of a compound list on load.
        %{"" => inner} = value when type == :compound and map_size(value) == 1 -> canon(inner)
        value -> canon({type, value})
      end)

    [<<length(values)::32>>, elements]
  end

  defp payload(:compound, fields) do
    entries =
      for {name, tag} <- Enum.sort(fields), do: [<<byte_size(name)::32>>, name, canon(tag)]

    [<<map_size(fields)::32>>, entries]
  end
end
