defmodule Valimc.PlayerSpawnConnectionTest do
  use ExUnit.Case, async: false
  # Drives sockets and changes the app-wide respawn radius and border (VMC-027e).
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.World.{Border, Clock, Spawn}

  setup do
    Application.put_env(:valimc, :respawn_radius, 10)

    on_exit(fn ->
      Application.put_env(:valimc, :respawn_radius, 0)
      Clock.border_command({:set, Border.max_size(), 0})
      Clock.border_command({:center, 0.0, 0.0})
    end)
  end

  defp join do
    name = "Spawn#{System.unique_integer([:positive])}"
    {_, client} = Client.login(name)
    on_exit(fn -> Client.close(client) end)
    client.pose
  end

  test "new players appear on a safe column within the respawn radius of the world spawn" do
    {sx, sy, sz} = Spawn.position()

    poses = for _ <- 1..4, do: join()

    for pose <- poses do
      assert abs(pose.x - (sx + 0.5)) <= 10 and abs(pose.z - (sz + 0.5)) <= 10
      assert pose.x - floor(pose.x) == 0.5 and pose.z - floor(pose.z) == 0.5
      # The preview's flat world: grass at 63, so everyone stands at 64.
      assert pose.y == sy * 1.0
    end
  end

  test "a world spawn outside the border moves to the border's centre" do
    assert {:ok, _} = Clock.border_command({:center, 1000.5, -2000.5})
    assert {:ok, _} = Clock.border_command({:set, 4.0, 0})
    pose = join()
    # Within the radius the border leaves: at most 1 block from the centre column.
    assert abs(pose.x - 1000.5) <= 1 and abs(pose.z - -2000.5) <= 1
  end
end
