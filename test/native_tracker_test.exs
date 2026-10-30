defmodule Valimc.NativeTrackerTest do
  @moduledoc """
  The native tracker (`valimc_core::tracker`, VMC-081i) against
  `Valimc.Entity.Tracker.tick_body/2`: the same spawn and the same packets
  every tick over random walks with turns, landings, far jumps, motion and
  data changes.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.EntityTypes
  alias Valimc.Entity.{NativeBody, Tracker, Tracking, View}
  alias Valimc.Native

  @id 4321
  @uuid <<9::128>>

  defp shown(flags), do: {[{:shared_flags, flags, 0}], [], %{}, nil}

  defp view(type, state) do
    %{
      kind: :mob,
      entity_id: @id,
      uuid: @uuid,
      type: type,
      at: state.at,
      velocity: state.velocity,
      on_ground: state.on_ground,
      yaw: state.yaw,
      pitch: state.pitch,
      head_yaw: state.head,
      events: [],
      body: %NativeBody{type: type, shown: shown(state.flags)}
    }
  end

  defp walk(seed, n) do
    :rand.seed(:exsss, {seed, 7, 11})
    start = %{at: {0.5, 64.0, 0.5}, velocity: {0.0, 0.0, 0.0}, on_ground: true}
    start = Map.merge(start, %{yaw: 0.0, pitch: 0.0, head: 0.0, flags: 0})

    Enum.scan(1..n, start, fn _, s ->
      {x, y, z} = s.at
      r = :rand.uniform()

      at =
        cond do
          r < 0.04 -> {x + 40.0 * (:rand.uniform() - 0.5), y, z}
          r < 0.5 -> {x + 0.4 * (:rand.uniform() - 0.5), y + 0.05 * (:rand.uniform() - 0.5), z}
          true -> s.at
        end

      velocity =
        if :rand.uniform() < 0.3,
          do: {0.2 * (:rand.uniform() - 0.5), -0.0784000015258789, 0.0},
          else: s.velocity

      %{
        s
        | at: at,
          velocity: if(:rand.uniform() < 0.1, do: {0.0, 0.0, 0.0}, else: velocity),
          on_ground: if(:rand.uniform() < 0.05, do: not s.on_ground, else: s.on_ground),
          yaw: if(:rand.uniform() < 0.3, do: s.yaw + 30.0 * (:rand.uniform() - 0.5), else: s.yaw),
          pitch: if(:rand.uniform() < 0.1, do: 40.0 * (:rand.uniform() - 0.5), else: s.pitch),
          head:
            if(:rand.uniform() < 0.3, do: s.head + 50.0 * (:rand.uniform() - 0.5), else: s.head),
          flags: if(:rand.uniform() < 0.05, do: Bitwise.bxor(s.flags, 2), else: s.flags)
      }
    end)
  end

  defp pack(s) do
    {x, y, z} = s.at
    {vx, vy, vz} = s.velocity

    <<x::float-64, y::float-64, z::float-64, s.yaw::float-64, s.pitch::float-64, s.head::float-64,
      vx::float-64, vy::float-64, vz::float-64, if(s.on_ground, do: 1, else: 0)>>
  end

  for type <- ["minecraft:zombie", "minecraft:bat", "minecraft:ender_dragon", "minecraft:squid"] do
    test "#{type}'s native tracker sends what the Elixir one sends" do
      type = unquote(type)
      facts = EntityTypes.fetch(type)

      for seed <- 1..4 do
        [first | _] = states = walk(seed, 900)
        tracker = Tracker.new_body(view(type, first))

        # Each tick's data changes, as the owner encodes them for the section.
        {changes, _} =
          Enum.map_reduce(states, first.flags, fn s, flags ->
            packets =
              if s.flags == flags,
                do: [],
                else:
                  NativeBody.shown_changes(
                    @id,
                    %NativeBody{shown: shown(flags)},
                    %NativeBody{shown: shown(s.flags)}
                  )

            {IO.iodata_to_binary(Tracking.encode(@id, packets)), s.flags}
          end)

        {spawn, frames} =
          Native.tracker_parity(
            @id,
            @uuid,
            facts.id,
            facts.update_interval,
            facts.track_deltas,
            Tracking.packet_ids(),
            states |> Enum.map(&pack/1) |> IO.iodata_to_binary(),
            changes
          )

        assert length(frames) == length(states)
        assert frames |> Enum.map(&length(Tracking.decode(&1))) |> Enum.sum() > 300
        first_view = view(type, first)
        {add_entity, expected} = View.spawn(first_view, first.at, first.velocity)
        assert {add_entity, spawn} == {add_entity, expected}

        Enum.zip(states, frames)
        |> Enum.with_index()
        |> Enum.reduce(tracker, fn {{state, frame}, tick}, tracker ->
          {tracker, packets} = Tracker.tick_body(tracker, view(type, state))

          assert Tracking.decode(frame) == Enum.map(packets, &{@id, &1}),
                 "#{type} seed #{seed} tick #{tick}"

          tracker
        end)
      end
    end
  end
end
