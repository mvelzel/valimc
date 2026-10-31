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

defmodule Valimc.WorldSettingsTest.Serial do
  @moduledoc "Commands that change the running world's settings or read every region."
  # The spawn, the default game mode and the region registry are global.
  use ExUnit.Case, async: false
  alias Valimc.Commands.Source
  alias Valimc.World.{Settings, Spawn}

  # An RCON source in `dimension`: its collected output is the command's feedback text.
  defp run(dimension, input) do
    source = %{Source.rcon() | dimension: dimension}
    Valimc.Commands.run(source, input)
    Source.collect(source)
  end

  test "execute in and positioned change the source the command after run sees (VMC-083)" do
    previous = Settings.get(:spawn)
    on_exit(fn -> Settings.put(spawn: previous) end)

    run(:overworld, "execute in minecraft:the_nether positioned 5 80 6 run setworldspawn ~ ~1 ~")
    assert Spawn.dimension() == :the_nether
    assert Spawn.position() == {5, 81, 6}
    assert run(:overworld, "execute in minecraft:nowhere run seed") =~ "nowhere"
    assert run(:overworld, "execute in minecraft:the_end") =~ "Unknown or incomplete"
  end

  test "setworldspawn keeps the executing dimension and pitch; defaultgamemode persists" do
    previous = Settings.get(:spawn)
    mode = Settings.get(:default_game_mode)
    on_exit(fn -> Settings.put(spawn: previous, default_game_mode: mode) end)

    log = run(:the_nether, "setworldspawn 1 70 2 90 10")
    assert log =~ "minecraft:the_nether"
    assert Spawn.dimension() == :the_nether
    assert {Spawn.position(), Spawn.yaw(), Spawn.pitch()} == {{1, 70, 2}, 90.0, 10.0}
    assert Source.console().dimension == :the_nether

    run(:overworld, "defaultgamemode adventure")
    assert Settings.get(:default_game_mode) == :adventure
  end

  test "save-all from the Nether saves every dimension's regions and starts none" do
    {overworld, nether} = {{-31_001, 9}, {-31_002, 9}}
    {:ok, _} = Valimc.TestWorld.owner(overworld)

    {:ok, _} =
      Valimc.World.Dimension.within(:the_nether, fn -> Valimc.TestWorld.owner(nether) end)

    scoped = [
      Valimc.TestWorld.section(overworld),
      Valimc.Data.Grid.section(:the_nether, nether, :section)
    ]

    on_exit(fn ->
      for key <- scoped,
          {pid, _} <- Valimc.TestWorld.registered(key),
          do: Valimc.TestScope.kill(pid)
    end)

    before = Registry.select(Valimc.RegionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    assert run(:the_nether, "save-all flush") =~ "Saved the game"
    after_save = Registry.select(Valimc.RegionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    assert Enum.sort(after_save) == Enum.sort(before)

    owners = Valimc.Commands.Server.owners() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    for key <- scoped,
        [{pid, _}] = Valimc.TestWorld.registered(key),
        do: assert(MapSet.member?(owners, pid))
  end

  test "locate searches the executing dimension's generator" do
    # ValiMC's flat profile has no overworld structures, but its Nether has fortresses.
    assert run(:overworld, "locate structure minecraft:fortress") =~ "flat preview"

    assert run(:the_nether, "locate structure minecraft:fortress") =~
             "The nearest minecraft:fortress"
  end
end
