defmodule Valimc.World.SleepStatus do
  @moduledoc """
  Who sleeps in each dimension and when the night skips (VMC-040a), as
  vanilla's `SleepStatus` and `ServerLevel.tick` decide it. The environment
  owner (`Valimc.World.Clock`) keeps it: a session tells it when its player
  lies down, has slept long enough (100 ticks, `isSleepingLongEnough`) and
  gets up, so nothing reaches the owner while nobody sleeps.

  While someone sleeps, each tick counts the dimension's players that are
  not spectators (from the published player list). Enough of them sleep
  when at least `needed/2` do (the `players_sleeping_percentage` share,
  rounded up, at least one); the night skips when that many sleep and that
  many slept long enough. A change of either count with a sleeper before
  or after it tells every player of the dimension how many sleep, as
  vanilla's `announceSleepStatus`, unless the percentage is above 100 (no
  night skips then).
  """
  alias Valimc.Data.Float32
  alias Valimc.Protocol.Packets
  alias Valimc.Text

  defstruct sleepers: %{}, counts: %{}

  @doc "How many must sleep of `active` players at `percentage` (`sleepersNeeded`)."
  def needed(active, percentage),
    do: max(1, ceil(Float32.round(active * percentage / 100.0)))

  @doc "Whether `sleeping` of `active` players are enough at `percentage`."
  def enough?(sleeping, active, percentage), do: sleeping >= needed(active, percentage)

  @doc """
  `uuid` (whose connection is `connection`) lay down (`:asleep`), slept long
  enough (`:deep`) or got up (`:awake`) in `dimension`.
  """
  def change(%__MODULE__{} = status, uuid, _dimension, :awake, _connection),
    do: %{status | sleepers: Map.delete(status.sleepers, uuid)}

  def change(%__MODULE__{} = status, uuid, dimension, kind, connection)
      when kind in [:asleep, :deep] do
    sleeper = %{dimension: dimension, connection: connection, deep: kind == :deep}
    %{status | sleepers: Map.put(status.sleepers, uuid, sleeper)}
  end

  @doc """
  One tick: `{status, actions}`. `active` gives a dimension's players that
  are not spectators (`[{connection, uuid}]`). Actions are `{:announce,
  connections, text}` and `{:skip, dimension, connections}` (the sleepers to
  wake).
  """
  def tick(%__MODULE__{} = status, active, percentage) do
    dimensions =
      Enum.uniq(Enum.map(Map.values(status.sleepers), & &1.dimension) ++ Map.keys(status.counts))

    Enum.reduce(dimensions, {status, []}, fn dimension, {status, actions} ->
      players = active.(dimension)
      uuids = MapSet.new(players, &elem(&1, 1))

      sleepers =
        for {uuid, s} <- status.sleepers,
            s.dimension == dimension and MapSet.member?(uuids, uuid),
            do: {uuid, s}

      count = {length(players), length(sleepers)}
      {old_active, old_sleeping} = Map.get(status.counts, dimension, {0, 0})
      {active_count, sleeping} = count

      announce =
        if (old_sleeping > 0 or sleeping > 0) and count != {old_active, old_sleeping} and
             percentage <= 100 do
          text =
            if enough?(sleeping, active_count, percentage),
              do: Text.translatable("sleep.skipping_night"),
              else:
                Text.translatable("sleep.players_sleeping", [
                  sleeping,
                  needed(active_count, percentage)
                ])

          [{:announce, Enum.map(players, &elem(&1, 0)), text}]
        else
          []
        end

      deep = Enum.count(sleepers, fn {_, s} -> s.deep end)

      if enough?(sleeping, active_count, percentage) and enough?(deep, active_count, percentage) do
        woken = Enum.map(sleepers, fn {_, s} -> s.connection end)

        status = %{
          status
          | sleepers: Map.drop(status.sleepers, Enum.map(sleepers, &elem(&1, 0))),
            counts: Map.put(status.counts, dimension, {active_count, 0})
        }

        {status, actions ++ announce ++ [{:skip, dimension, woken}]}
      else
        counts =
          if sleeping == 0,
            do: Map.delete(status.counts, dimension),
            else: Map.put(status.counts, dimension, count)

        {%{status | counts: counts}, actions ++ announce}
      end
    end)
  end

  @doc "The packet of an announcement's `text`."
  def packet(text), do: Packets.overlay(text)
end
