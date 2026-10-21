defmodule Valimc.WorldSettingsTest do
  @moduledoc """
  The world's durable settings and its generation spec (VMC-077a): settings are
  written crash-safely before they are published; `world.json` is read once and
  a failure to read it is an error, never flat terrain.
  """
  use ExUnit.Case, async: true
  alias Valimc.World.{Settings, Spec}

  @moduletag :tmp_dir

  test "a private owner saves each change before publishing it", %{tmp_dir: dir} do
    {:ok, owner} = Settings.start_link(dir: dir, name: nil)
    assert Settings.read(dir) == {:ok, %{}}

    spawn = %{dimension: :the_nether, position: {-12, 78, 300}, yaw: 90.0, pitch: 12.5}
    assert Settings.put(owner, spawn: spawn, default_game_mode: :survival) == :ok
    assert Settings.put(owner, default_game_mode: :survival) == :unchanged
    assert Settings.read(dir) == {:ok, %{spawn: spawn, default_game_mode: :survival}}

    # A restarted owner reads what was saved; nothing else was written beside it.
    GenServer.stop(owner)
    {:ok, owner} = Settings.start_link(dir: dir, name: nil)
    assert Settings.put(owner, white_list: true, idle_timeout: 5) == :ok
    assert File.ls!(dir) == ["settings.json"]

    assert {:ok, %{white_list: true, idle_timeout: 5, spawn: ^spawn}} = Settings.read(dir)
  end

  test "a failed write changes nothing", %{tmp_dir: dir} do
    {:ok, owner} = Settings.start_link(dir: Path.join(dir, "world"), name: nil)
    # The world directory cannot be created where a file stands.
    File.write!(Path.join(dir, "world"), "")
    assert {:error, _} = Settings.put(owner, default_game_mode: :adventure)
    # Still not adventure: the owner tries again rather than answering `:unchanged`.
    assert {:error, _} = Settings.put(owner, default_game_mode: :adventure)
  end

  test "unreadable settings and old formats are refused", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "settings.json"), ~s({"default_game_mode": "hardcore"}))
    assert {:error, {:invalid_settings, _}} = Settings.read(dir)
    Process.flag(:trap_exit, true)

    assert {:error, {:settings_unavailable, {:invalid_settings, _}}} =
             Settings.start_link(dir: dir, name: nil)

    File.rm!(Path.join(dir, "settings.json"))
    File.write!(Path.join(dir, "admin-settings.json"), ~s({"white-list": true}))
    assert {:error, {:settings_format_too_old, _}} = Settings.read(dir)
  end

  test "world.json is read once; a broken one is an error, never flat", %{tmp_dir: dir} do
    # No world.json: ValiMC's flat profile.
    assert {:ok, %Spec{generator: :flat} = flat} = Spec.load(dir)
    assert Spec.generation(flat, :overworld) == nil
    assert {:ok, %{noise_settings: "minecraft:nether"}} = Spec.generation(flat, :the_nether)

    :ok = Spec.write(dir, %{"type" => "vanilla", "seed" => 5, "features" => true})
    assert {:ok, %Spec{generator: :vanilla, seed: 5} = vanilla} = Spec.load(dir)
    assert {:ok, %{kind: :noise, seed: 5}} = Spec.generation(vanilla, :overworld)
    assert Spec.decorated?(vanilla, :overworld) and Spec.decorated?(vanilla, :the_end)

    File.write!(Spec.path(dir), ~s({"generator": {"type": "vanilla", "seed"))
    assert {:error, {:invalid_world_metadata, _}} = Spec.load(dir)
    assert catch_exit(Spec.fetch(dir)) |> elem(0) == :world_unavailable

    # A world.json from before VMC-077a keeps the spawn; it is not migrated.
    File.write!(Spec.path(dir), ~s({"spawn": [0, 64, 0], "generator": {"type": "flat"}}))
    assert {:error, {:world_format_too_old, _}} = Spec.load(dir)

    File.rm!(Spec.path(dir))
    File.mkdir!(Spec.path(dir))
    assert {:error, {:world_metadata_unreadable, _, :eisdir}} = Spec.load(dir)
  end
end
