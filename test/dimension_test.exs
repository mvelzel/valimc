defmodule Valimc.DimensionTest do
  use ExUnit.Case, async: true
  alias Valimc.{Dimension, Inventory}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Anvil.Light
  alias Valimc.Protocol.Wire

  defp uuid, do: <<41::128>>
  defp pose, do: %{x: 8.5, y: 70.0, z: -3.5, yaw: 90.0, pitch: 0.0}

  test "the context is per process and bound into tasks" do
    assert Dimension.current() == :overworld

    Dimension.within(:the_nether, fn ->
      task = Task.async(Dimension.bind(fn -> Dimension.current() end))
      assert Task.await(task) == :the_nether
      assert Task.await(Task.async(fn -> Dimension.current() end)) == :overworld
    end)

    assert Dimension.current() == :overworld
  end

  # The light part as {sky mask, block mask, empty sky, empty block, sky arrays, block arrays}.
  defp light(iodata) do
    bytes = IO.iodata_to_binary(iodata)
    {sky, rest} = bitset(bytes)
    {block, rest} = bitset(rest)
    {empty_sky, rest} = bitset(rest)
    {empty_block, rest} = bitset(rest)
    {skies, rest} = arrays(rest)
    {blocks, <<>>} = arrays(rest)
    {sky, block, empty_sky, empty_block, skies, blocks}
  end

  defp bitset(bytes) do
    {length, rest} = Wire.take_varint(bytes)
    <<value::binary-size(^length), rest::binary>> = rest
    {:binary.decode_unsigned(value, :little), rest}
  end

  defp arrays(bytes) do
    {count, rest} = Wire.take_varint(bytes)

    Enum.map_reduce(List.duplicate(nil, count), rest, fn _, rest ->
      {2048, <<data::binary-size(2048), rest::binary>>} = Wire.take_varint(rest)
      {data, rest}
    end)
  end

  test "light packets carry the dimension's sections, and no sky light in the Nether" do
    full = Bitwise.bsl(1, 18) - 1
    assert {^full, 0, 0, ^full, skies, []} = light(Light.packet(nil, :the_end))
    assert length(skies) == 18
    assert {0, 0, 0, ^full, [], []} = light(Light.packet(nil, :the_nether))
    assert {sky, 0, 0, _, overworld, []} = light(Light.packet(nil, :overworld))
    assert sky == Bitwise.bsl(1, 26) - 1 and length(overworld) == 26

    # Image sections 4..21 are the Nether's (y −16..271); section 5 is y 0..15.
    lit = :binary.copy(<<0x77>>, 2048)

    image =
      IO.iodata_to_binary(
        for i <- 0..25 do
          [<<1, 255>>, if(i == 5, do: [<<2>>, lit], else: <<0>>)]
        end
      )

    assert {0, 0b10, 0, 0, [], [^lit]} = light(Light.packet(image, :the_nether))
    {end_sky, 0b10, 0, 0, end_skies, [^lit]} = light(Light.packet(image, :the_end))
    assert end_sky == full and length(end_skies) == 18
  end

  test "the Nether's and the End's generators follow the world's recorded settings" do
    alias Valimc.World.{GenSettings, Spec}
    base = Path.join(System.tmp_dir!(), "valimc-dimgen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    record = fn settings ->
      :ok = Spec.write(base, %{"type" => "vanilla", "seed" => 5, "settings" => settings})
    end

    generation = &Spec.generation(Spec.fetch(base), &1)

    # A world without recorded settings (ValiMC's flat profile) takes the defaults.
    assert {:ok, %{noise_settings: "minecraft:nether", biome_source: "minecraft:nether"}} =
             generation.(:the_nether)

    settings = GenSettings.create("minecraft:normal", nil, 5, true)
    record.(settings)

    assert {:ok, %{seed: 5, noise_settings: "minecraft:nether", biome_source: "minecraft:nether"}} =
             generation.(:the_nether)

    assert {:ok, %{noise_settings: "minecraft:end", biome_source: "minecraft:the_end"}} =
             generation.(:the_end)

    deltas = %{"type" => "minecraft:fixed", "biome" => "minecraft:basalt_deltas"}

    record.(
      put_in(
        settings,
        ["dimensions", "minecraft:the_nether", "generator", "biome_source"],
        deltas
      )
    )

    assert {:ok, %{biome_source: "fixed:minecraft:basalt_deltas"}} =
             generation.(:the_nether)

    checkerboard = %{"type" => "minecraft:checkerboard", "biomes" => ["minecraft:plains"]}

    record.(
      put_in(
        settings,
        ["dimensions", "minecraft:the_end", "generator", "biome_source"],
        checkerboard
      )
    )

    assert {:error, {:unsupported_biome_source, "minecraft:the_end", _}} =
             generation.(:the_end)
  end
end
