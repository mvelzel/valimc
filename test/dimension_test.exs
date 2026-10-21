defmodule Valimc.DimensionTest do
  use ExUnit.Case, async: true
  alias Valimc.{Dimension, Inventory, PlayerSnapshot}
  alias Valimc.Anvil.Light
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.World.Chunk

  defp uuid, do: <<41::128>>
  defp pose, do: %{x: 8.5, y: 70.0, z: -3.5, yaw: 90.0, pitch: 0.0}

  test "dimension types and bounds come from the generated facts" do
    nether = Dimension.facts(:the_nether)
    assert nether.type_id == Data.registry_id("minecraft:dimension_type", "minecraft:the_nether")
    assert {nether.min_y, nether.height, nether.logical_height} == {0, 256, 128}
    assert not nether.sky_light and nether.ceiling and nether.coordinate_scale == 8.0
    assert nether.sea_level == 32
    the_end = Dimension.facts(:the_end)
    assert the_end.sky_light and the_end.fixed_time and the_end.dragon_fight
    assert Dimension.facts(:overworld).type_id == 0
    assert Dimension.section_window(:overworld) == {0, 24}
    assert Dimension.section_window(:the_nether) == {4, 16}
    assert Dimension.section_window(:the_end) == {4, 16}
  end

  test "keys, names and storage folders are scoped per dimension" do
    assert Dimension.scope(:overworld, {1, 2}) == {1, 2}
    assert Dimension.scope(:the_nether, {1, 2}) == {:the_nether, {1, 2}}
    assert Dimension.unscope({:the_end, {1, 2}}) == {:the_end, {1, 2}}
    assert Dimension.unscope({1, 2}) == {:overworld, {1, 2}}
    assert Dimension.parse("minecraft:the_nether") == {:ok, :the_nether}
    assert Dimension.parse("the_end") == {:ok, :the_end}
    assert Dimension.parse("minecraft:the_moon") == :error
    assert Dimension.storage("w", :overworld) == "w"
    assert Dimension.storage("w", :the_nether) == "w/dimensions/minecraft/the_nether"
    assert Dimension.storage("w", :the_end) == "w/dimensions/minecraft/the_end"
  end

  test "the context is per process and bound into tasks" do
    assert Dimension.current() == :overworld

    Dimension.within(:the_nether, fn ->
      assert Dimension.scope({0, 0}) == {:the_nether, {0, 0}}
      task = Task.async(Dimension.bind(fn -> Dimension.current() end))
      assert Task.await(task) == :the_nether
      assert Task.await(Task.async(fn -> Dimension.current() end)) == :overworld
    end)

    assert Dimension.current() == :overworld
  end

  test "the build height and base profile follow the caller's dimension" do
    assert Chunk.valid_y?(-64) and Chunk.valid_y?(319)
    assert Chunk.base(0) == Data.block("stone")

    Dimension.within(:the_nether, fn ->
      refute Chunk.valid_y?(-1) or Chunk.valid_y?(256)
      assert Chunk.valid_y?(0) and Chunk.valid_y?(255)
      assert Chunk.base(0) == Data.block("air") and Chunk.base(-64) == Data.block("air")
    end)
  end

  test "snapshots name the dimension, the death's dimension and the portal cooldown" do
    base = %{pose: pose(), inventory: %Inventory{}}
    assert {:ok, <<"VMCPOSE", 2, _::binary>> = plain} = PlayerSnapshot.encode(uuid(), base)

    # Overworld players off cooldown keep the version they had.
    overworld =
      Map.merge(base, %{dimension: :overworld, death_dimension: :overworld, portal_cooldown: 0})

    assert {:ok, ^plain} = PlayerSnapshot.encode(uuid(), overworld)

    nether =
      Map.merge(base, %{dimension: :the_nether, death_dimension: :the_end, portal_cooldown: 7})

    assert {:ok, <<"VMCPOSE", 22, _::binary>> = bytes} = PlayerSnapshot.encode(uuid(), nether)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid())

    assert {restored.dimension, restored.death_dimension, restored.portal_cooldown} ==
             {:the_nether, :the_end, 7}

    assert restored.pose == pose()
    assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid(), restored)

    assert {:error, :invalid_dimension} =
             PlayerSnapshot.encode(uuid(), %{nether | dimension: :moon})

    player =
      Map.merge(pose(), %{dimension: :the_end, death_dimension: :overworld, portal_cooldown: 3})

    captured = PlayerSnapshot.capture(player, %Inventory{})
    assert {captured.dimension, captured.portal_cooldown} == {:the_end, 3}
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
    alias Valimc.World.{GenSettings, Generator}
    base = Path.join(System.tmp_dir!(), "valimc-dimgen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    record = fn settings ->
      File.write!(
        Valimc.World.Spawn.path(base),
        JSON.encode!(%{
          "spawn" => [0, 64, 0],
          "generator" => %{"type" => "vanilla", "seed" => 5, "settings" => settings}
        })
      )
    end

    # A world without recorded settings (ValiMC's flat profile) takes the defaults.
    assert {:ok, %{noise_settings: "minecraft:nether", biome_source: "minecraft:nether"}} =
             Generator.spec(base, :the_nether)

    settings = GenSettings.create("minecraft:normal", nil, 5, true)
    record.(settings)

    assert {:ok, %{seed: 5, noise_settings: "minecraft:nether", biome_source: "minecraft:nether"}} =
             Generator.spec(base, :the_nether)

    assert {:ok, %{noise_settings: "minecraft:end", biome_source: "minecraft:the_end"}} =
             Generator.spec(base, :the_end)

    deltas = %{"type" => "minecraft:fixed", "biome" => "minecraft:basalt_deltas"}

    record.(
      put_in(
        settings,
        ["dimensions", "minecraft:the_nether", "generator", "biome_source"],
        deltas
      )
    )

    assert {:ok, %{biome_source: "fixed:minecraft:basalt_deltas"}} =
             Generator.spec(base, :the_nether)

    checkerboard = %{"type" => "minecraft:checkerboard", "biomes" => ["minecraft:plains"]}

    record.(
      put_in(
        settings,
        ["dimensions", "minecraft:the_end", "generator", "biome_source"],
        checkerboard
      )
    )

    assert {:error, {:unsupported_biome_source, "minecraft:the_end", _}} =
             Generator.spec(base, :the_end)
  end
end
