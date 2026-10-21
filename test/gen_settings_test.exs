defmodule Valimc.GenSettingsTest do
  @moduledoc """
  World generation settings (VMC-028a): created as a dedicated server creates
  them, converted to and from `world_gen_settings.dat`, recorded on import and
  written on export. Vanilla parity is stage `world_settings`.
  """
  use ExUnit.Case, async: true
  alias Valimc.NBT
  alias Valimc.World.{GenSettings, Generator, Settings, Spec}

  defp hashed(seed) do
    <<hashed::little-signed-64, _::binary>> = :crypto.hash(:sha256, <<seed::little-signed-64>>)
    hashed
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "valimc-settings-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "worlds record their settings; older and flat worlds get theirs", ctx do
    :ok = Generator.create(ctx.dir, 20_261_020, features: false, structures: false)
    spec = Spec.fetch(ctx.dir)
    assert spec.settings == GenSettings.create("minecraft:normal", nil, 20_261_020, false)
    assert Spec.client_info(spec, :overworld) == {hashed(20_261_020), false}

    # Presets ValiMC does not generate yet are refused.
    other = Path.join(ctx.dir, "other")

    assert {:error, {:unsupported_generator, _}} =
             Generator.create(other, 1, level_type: "minecraft:debug_all_block_states")

    older = Path.join(ctx.dir, "older")
    File.mkdir_p!(older)

    :ok = Spec.write(older, %{"type" => "vanilla", "seed" => 5})
    assert Spec.fetch(older).settings == GenSettings.create("minecraft:normal", nil, 5, true)

    flat = Spec.fetch(Path.join(ctx.dir, "flat"))
    assert flat.settings == nil
    assert GenSettings.overworld(Spec.settings(flat))["type"] == "minecraft:flat"
    assert Spec.client_info(flat, :overworld) == {0, true}
  end

  test "an import records the world's settings; an export writes them", ctx do
    source = Path.join(ctx.dir, "vanilla")
    File.mkdir_p!(Path.join(source, "dimensions/minecraft/overworld/region"))
    File.mkdir_p!(Path.join(source, "data/minecraft"))
    version = {:int, Valimc.Version.data_version()}

    level =
      {:compound,
       %{
         "Data" =>
           {:compound,
            %{
              "DataVersion" => version,
              "spawn" =>
                {:compound,
                 %{
                   "dimension" => {:string, "minecraft:the_nether"},
                   "pos" => {:int_array, <<1::32, 70::32, 2::32>>},
                   "pitch" => {:float, <<15.0::float-32>>}
                 }}
            }}
       }}

    File.write!(Path.join(source, "level.dat"), NBT.write_compressed(level, :gzip))
    settings = GenSettings.create("minecraft:large_biomes", nil, 777, true)
    {:ok, root} = GenSettings.to_nbt(settings)

    File.write!(
      Path.join(source, "data/minecraft/world_gen_settings.dat"),
      NBT.write_compressed(root, :gzip)
    )

    imported = Path.join(ctx.dir, "imported")
    {:ok, _} = Valimc.Anvil.Import.run(source, imported)
    {:ok, meta} = imported |> Spec.path() |> File.read!() |> JSON.decode()
    assert meta["generator"] == %{"type" => "imported", "seed" => 777, "settings" => settings}
    # Imports keep flat terrain outside their chunks, but clients get the seed.
    spec = Spec.fetch(imported)
    assert Spec.generation(spec, :overworld) == nil
    assert Spec.client_info(spec, :overworld) == {hashed(777), false}

    assert Settings.read(imported) ==
             {:ok,
              %{spawn: %{dimension: :the_nether, position: {1, 70, 2}, yaw: 0.0, pitch: 15.0}}}

    # A world never imported exports a level.dat at its spawn and its settings.
    created = Path.join(ctx.dir, "created")
    :ok = Generator.create(created, 99, features: false)
    exported = Path.join(ctx.dir, "exported")
    {:ok, _} = Valimc.Anvil.Export.run(created, exported)

    {:ok, written} =
      exported
      |> Path.join("data/minecraft/world_gen_settings.dat")
      |> File.read!()
      |> NBT.read_compressed(:gzip)

    assert GenSettings.from_nbt(written) == {:ok, Spec.fetch(created).settings}

    {:ok, {:compound, %{"Data" => {:compound, data}}}} =
      exported |> Path.join("level.dat") |> File.read!() |> NBT.read_compressed(:gzip)

    {:ok, %{spawn: %{position: {x, y, z}}}} = Settings.read(created)

    assert {:compound,
            %{
              "dimension" => {:string, "minecraft:overworld"},
              "pos" => {:int_array, <<^x::signed-32, ^y::signed-32, ^z::signed-32>>}
            }} = data["spawn"]

    assert data["DataVersion"] == version
  end
end
