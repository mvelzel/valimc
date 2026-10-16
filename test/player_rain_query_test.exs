defmodule Valimc.PlayerRainQueryTest do
  use ExUnit.Case, async: false
  alias Valimc.PlayerRainQuery
  alias Valimc.Physics.{BlockCollisions, PlayerPose}
  alias Valimc.World
  alias Valimc.World.{Clock, Region}

  setup do
    key = {982, 800}
    {:ok, owner} = World.owner(key)
    assert :ok = Clock.configure({:advance_weather, false})
    assert :ok = Clock.configure({:weather, :rain, 600})
    await_wet(true)

    on_exit(fn ->
      Clock.configure({:weather, :clear, 0})
      Clock.configure({:advance_weather, true})

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end)

    %{owner: owner, x: 982 * 128 + 4, z: 800 * 128 + 4}
  end

  test "rain observes roof additions/removals at the exact block fence, including transparent shelter",
       ctx do
    position = {ctx.x + 0.5, 64.0, ctx.z + 0.5}
    {:ok, geometry} = PlayerPose.geometry(:standing, position)
    before = frame(ctx.owner)
    assert PlayerRainQuery.sample(position, geometry, before) == {:ok, true}
    roof = {ctx.x, 66, ctx.z}
    assert :ok = World.set_block(roof, 1)
    assert PlayerRainQuery.sample(position, geometry, before) == {:error, :stale_revision}
    assert PlayerRainQuery.sample(position, geometry, frame(ctx.owner)) == {:ok, false}
    assert :ok = World.remove_block(roof)
    assert PlayerRainQuery.sample(position, geometry, frame(ctx.owner)) == {:ok, true}
    assert :ok = World.set_block(roof, Valimc.Protocol.Data.block("glass"))
    assert PlayerRainQuery.sample(position, geometry, frame(ctx.owner)) == {:ok, false}
    assert :ok = World.remove_block(roof)
    high = {ctx.x + 0.5, 1024.0, ctx.z + 0.5}
    {:ok, geometry} = PlayerPose.geometry(:standing, high)
    assert PlayerRainQuery.sample(high, geometry, frame(ctx.owner)) == {:ok, false}
  end

  test "wet observations need the current body's owner; dry weather performs no column read",
       ctx do
    position = {ctx.x + 0.5, 64.0, ctx.z + 0.5}
    {:ok, geometry} = PlayerPose.geometry(:swimming, position)
    empty = %BlockCollisions.Frame{states: %{}, fences: %{}, entities: %{}}
    assert PlayerRainQuery.sample(position, geometry, empty) == {:error, :rain_source_unavailable}
    assert :ok = Clock.configure({:weather, :clear, 0})
    await_wet(false)
    assert PlayerRainQuery.sample(position, geometry, empty) == {:ok, false}
  end

  defp frame(owner) do
    {:ok, observation} = Region.observe_blocks(owner, [])
    {:ok, frame} = BlockCollisions.prepare([observation])
    frame
  end

  defp await_wet(wet, remaining \\ 200)
  defp await_wet(_, 0), do: flunk("Weather did not reach its native wet threshold")

  defp await_wet(wet, remaining) do
    if Clock.weather().wet != wet do
      Process.sleep(10)
      await_wet(wet, remaining - 1)
    end
  end
end
