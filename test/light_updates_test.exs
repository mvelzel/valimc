defmodule Valimc.LightUpdatesTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Jobs, LightUpdates, RegionData}

  test "pending masks coalesce and ignore chunks no client requested" do
    state = %RegionData{
      jobs: %Jobs{},
      light_pending: %{},
      light_retry: true,
      served: MapSet.new([{0, 0}])
    }

    state = LightUpdates.queue(state, [{{0, 0}, 1, 2}, {{1, 0}, 8, 8}], :border)
    state = LightUpdates.queue(state, [{{0, 0}, 4, 1}], :all)
    assert state.light_pending == %{{0, 0} => {:all, 5, 3}}
  end

  test "a stale worker frame is retried with the latest image instead of being published" do
    key = {99_001, 99_001}

    state = %RegionData{
      key: key,
      dimension: :overworld,
      epoch: make_ref(),
      jobs: %Jobs{},
      light_pending: %{{1, 0} => {:border, 4, 8}},
      light_retry: true,
      versions: %{{0, 0} => 1, {1, 0} => 3}
    }

    Valimc.TestWorld.subscribe(MapSet.new([key]), MapSet.new())
    job = %{versions: %{{0, 0} => {1, {:border, 1, 2}}, {1, 0} => {2, {:all, 2, 1}}}}
    frames = %{{0, 0} => {{:light, {0, 0}}, <<1>>}, {1, 0} => {{1, 0}, <<2>>}}
    next = LightUpdates.done(state, job, frames)
    assert_receive {:event, {:block_batch, [{{:light, {0, 0}}, <<1>>}]}}
    assert next.light_pending == %{{1, 0} => {:all, 6, 9}}
    failed = LightUpdates.failed(state, job)
    assert failed.light_pending == %{{0, 0} => {:border, 1, 2}, {1, 0} => {:all, 6, 9}}
  end
end
