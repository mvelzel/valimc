defmodule Valimc.WorldSpawnTest do
  @moduledoc "The world spawn comes from world.json (imports) or defaults to (0, 64, 0) (VMC-021d)."
  # The spawn is one global value for the running world.
  use ExUnit.Case, async: false
  alias Valimc.World.Spawn

  @moduletag :tmp_dir

  setup do
    previous = Application.get_env(:valimc, :world_path)

    on_exit(fn ->
      Application.put_env(:valimc, :world_path, previous)
      Spawn.load!()
    end)
  end

  test "a world's spawn file sets position, yaw and the player pose", %{tmp_dir: dir} do
    Application.put_env(:valimc, :world_path, dir)
    Spawn.load!()
    assert Spawn.position() == {0, 64, 0}
    assert Spawn.pose() == %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}

    :ok = Spawn.write(dir, {-12, 78, 300}, 90.0)
    Spawn.load!()
    assert Spawn.position() == {-12, 78, 300}
    assert Spawn.pose() == %{x: -11.5, y: 78.0, z: 300.5, yaw: 90.0, pitch: 0.0}

    File.write!(Spawn.path(dir), "{\"spawn\": [1, 2]}")
    Spawn.load!()
    assert Spawn.position() == {0, 64, 0}
  end
end
