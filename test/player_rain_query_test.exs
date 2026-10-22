defmodule Valimc.PlayerRainQueryTest do
  use ExUnit.Case, async: false
  alias Valimc.Player.RainQuery
  alias Valimc.Data.PlayerPose
  alias Valimc.World
  alias Valimc.World.{Clock, View}

  setup do
    key = {982, 800}
    {:ok, owner} = Valimc.TestWorld.owner(key)
    assert :ok = Clock.configure({:advance_weather, false})
    weather(:rain)

    on_exit(fn ->
      weather(:clear)
      Clock.configure({:advance_weather, true})

      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end)

    %{owner: owner, x: 982 * 128 + 4, z: 800 * 128 + 4}
  end

  defp view(x, z), do: View.load_chunks(View.new(), [World.chunk_key(x, z)])

  test "rain sees roofs, including transparent shelter, from the published column", ctx do
    position = {ctx.x + 0.5, 64.0, ctx.z + 0.5}
    {:ok, geometry} = PlayerPose.geometry(:standing, position)

    assert RainQuery.sample(position, elem(geometry.box, 4), view(ctx.x, ctx.z)) ==
             {:ok, true}

    roof = {ctx.x, 66, ctx.z}
    assert :ok = Valimc.TestBlocks.set(roof, 1)

    assert RainQuery.sample(position, elem(geometry.box, 4), view(ctx.x, ctx.z)) ==
             {:ok, false}

    assert :ok = Valimc.TestBlocks.remove(roof)

    assert RainQuery.sample(position, elem(geometry.box, 4), view(ctx.x, ctx.z)) ==
             {:ok, true}

    assert :ok = Valimc.TestBlocks.set(roof, Valimc.Protocol.Data.block("glass"))

    assert RainQuery.sample(position, elem(geometry.box, 4), view(ctx.x, ctx.z)) ==
             {:ok, false}

    assert :ok = Valimc.TestBlocks.remove(roof)
    high = {ctx.x + 0.5, 1024.0, ctx.z + 0.5}
    {:ok, geometry} = PlayerPose.geometry(:standing, high)
    assert RainQuery.sample(high, elem(geometry.box, 4), view(ctx.x, ctx.z)) == {:ok, false}
  end

  test "unrelated block changes and a busy owner never stale or delay a rain answer", ctx do
    position = {ctx.x + 0.5, 64.0, ctx.z + 0.5}
    {:ok, geometry} = PlayerPose.geometry(:standing, position)
    before = view(ctx.x, ctx.z)
    elsewhere = {ctx.x + 60, 70, ctx.z + 60}
    assert :ok = Valimc.TestBlocks.set(elsewhere, 1)
    assert RainQuery.sample(position, elem(geometry.box, 4), before) == {:ok, true}

    # An owner busy saving (here: stopped) is never asked.
    {pid, _} = ctx.owner
    :sys.suspend(pid)

    try do
      assert RainQuery.sample(position, elem(geometry.box, 4), view(ctx.x, ctx.z)) ==
               {:ok, true}
    after
      :sys.resume(pid)
    end
  end

  test "an unreadable column fails closed; dry weather reads nothing", ctx do
    position = {ctx.x + 0.5, 64.0, ctx.z + 0.5}
    {:ok, geometry} = PlayerPose.geometry(:swimming, position)
    empty = View.of(%{})

    assert RainQuery.sample(position, elem(geometry.box, 4), empty) ==
             {:error, :rain_column_unavailable}

    weather(:clear)
    assert RainQuery.sample(position, elem(geometry.box, 4), empty) == {:ok, false}
  end

  # Rain at its final intensity at once, instead of the 20-tick native ramp.
  defp weather(kind) do
    {level, duration} = if kind == :rain, do: {1.0, 600}, else: {0.0, 0}
    :sys.replace_state(Clock, &put_in(&1.data.weather.rain_level, level))
    assert :ok = Clock.configure({:weather, kind, duration})
    assert Clock.weather().wet == (kind == :rain)
  end
end
