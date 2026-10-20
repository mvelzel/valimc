defmodule Valimc.NbtNativeParityTest do
  @moduledoc "The native disk NBT reader returns exactly what the Elixir reader returns (VMC-020)."
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Valimc.NBT

  defp scalar do
    one_of([
      map(integer(-128..127), &{:byte, &1}),
      map(integer(-32_768..32_767), &{:short, &1}),
      map(integer(-2_147_483_648..2_147_483_647), &{:int, &1}),
      map(
        integer(),
        &{:long, max(min(&1, 9_223_372_036_854_775_807), -9_223_372_036_854_775_808)}
      ),
      map(binary(length: 4), &{:float, &1}),
      map(binary(length: 8), &{:double, &1}),
      map(binary(max_length: 16), &{:byte_array, &1}),
      map(list_of(binary(length: 4), max_length: 4), &{:int_array, IO.iodata_to_binary(&1)}),
      map(list_of(binary(length: 8), max_length: 4), &{:long_array, IO.iodata_to_binary(&1)}),
      map(string(:printable, max_length: 12), &{:string, &1}),
      map(string([0, ?a, 0xE9, 0x1F600], max_length: 6), &{:string, &1})
    ])
  end

  defp tag do
    tree(scalar(), fn child ->
      one_of([
        map(map_of(string(:alphanumeric, max_length: 6), child, max_length: 4), &{:compound, &1}),
        map(list_of(child, max_length: 4), &NBT.list/1)
      ])
    end)
  end

  defp root,
    do: map(map_of(string(:printable, max_length: 6), tag(), max_length: 6), &{:compound, &1})

  defp both(bytes, limits \\ NBT.disk_limits()),
    do: {NBT.read(bytes, limits), NBT.read_reference(bytes, limits)}

  property "generated roots read identically and round trip" do
    check all(root <- root()) do
      bytes = IO.iodata_to_binary(NBT.write(root))
      {native, reference} = both(bytes)
      assert native == reference
      assert native == {:ok, root}
    end
  end

  property "mutated, truncated and extended inputs give the same result or the same error" do
    check all(
            root <- root(),
            flips <- list_of({integer(0..10_000), integer(0..255)}, max_length: 3),
            cut <- integer(0..10_000),
            tail <- binary(max_length: 3),
            nodes <- integer(1..40),
            depth <- integer(1..6),
            bytes <- integer(8..400)
          ) do
      raw = IO.iodata_to_binary(NBT.write(root))

      mutated =
        Enum.reduce(flips, raw, fn {at, byte}, acc ->
          at = rem(at, byte_size(acc))
          <<head::binary-size(^at), _, rest::binary>> = acc
          <<head::binary, byte, rest::binary>>
        end)

      candidate = binary_part(mutated, 0, min(cut, byte_size(mutated))) <> tail
      {native, reference} = both(candidate)
      assert native == reference

      limits = %{NBT.disk_limits() | nodes: nodes, depth: depth, bytes: bytes}
      {native, reference} = both(candidate, limits)
      assert native == reference
    end
  end

  test "inputs past the normal-scheduler size run dirty, including 512 nested containers" do
    deep = Enum.reduce(2..511//1, {:list, {:end, []}}, fn _, inner -> NBT.list([inner]) end)

    root =
      {:compound, %{"pad" => {:long_array, :binary.copy(<<7::64>>, 40_000)}, "deep" => deep}}

    bytes = IO.iodata_to_binary(NBT.write(root))
    assert byte_size(bytes) > 131_072
    assert both(bytes) == {{:ok, root}, {:ok, root}}

    too_deep =
      {:compound,
       %{"pad" => {:byte_array, :binary.copy(<<0>>, 140_000)}, "deep" => NBT.list([deep])}}

    bytes = IO.iodata_to_binary(NBT.write(too_deep, %{NBT.disk_limits() | depth: 600}))
    assert both(bytes) == {{:error, :nbt_depth_limit}, {:error, :nbt_depth_limit}}
  end

  test "a repeated name keeps the last value natively too" do
    raw = <<10, 0::16, 3, 1::16, "a", 1::32, 8, 1::16, "a", 2::16, "hi", 0>>

    assert both(raw) ==
             {{:ok, {:compound, %{"a" => {:string, "hi"}}}},
              {:ok, {:compound, %{"a" => {:string, "hi"}}}}}
  end
end
