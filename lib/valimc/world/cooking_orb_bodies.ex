defmodule Valimc.World.CookingOrbBodies do
  @moduledoc "Bounded stored XP bodies; per-award initialization markers and terminal expiry never rewrite births."
  alias Valimc.Physics.OrbMotion
  alias Valimc.World.{Containers, CookingOrbs, Items}
  @max 18_446_744_073_709_551_615
  @max_bytes 10 + 256 * 33 + 2816 * 81
  def new, do: %{revision: 0, awards: %{}}
  def fence(cs), do: {cs.orb_bodies.revision, cs.orb_consumption.revision}

  @doc "Pure launch proposal. Supply draws only for uncollected units; replay never resamples them."
  def initialize(cs, key, id, decisions) when is_map(decisions) and map_size(decisions) <= 11 do
    with {:ok, _} <- Containers.encode(key, cs),
         {:ok, births} <- Map.fetch(CookingOrbs.owned_records(cs), id) do
      if Map.has_key?(cs.orb_bodies.awards, id) do
        {:ok, %{expected: fence(cs), bodies: cs.orb_bodies}}
      else
        active = Map.filter(births, fn {uuid, b} -> b.count > consumed(cs, uuid) end)
        true = MapSet.new(Map.keys(active)) == MapSet.new(Map.keys(decisions))
        revision = cs.orb_bodies.revision + 1

        rows =
          Map.new(births, fn {uuid, birth} ->
            launch =
              case Map.fetch(decisions, uuid) do
                {:ok, {direction, draws}} ->
                  {:ok, launch} = OrbMotion.launch(birth.position, direction, draws)
                  launch

                :error ->
                  %{position: doubles(birth.position), velocity: {0.0, 0.0, 0.0}}
              end

            {uuid,
             Map.merge(launch, %{
               revision: revision,
               age: 0,
               on_ground: false,
               no_gravity: false,
               expired: 0
             })}
          end)

        propose(cs, key, %{revision: revision, awards: Map.put(cs.orb_bodies.awards, id, rows)})
      end
    else
      :error -> {:error, :unknown_orb_award}
      error -> error
    end
  rescue
    _ -> invalid()
  end

  def initialize(_, _, _, _), do: invalid()

  @doc """
  Lifetime without motion (VMC-067): awards without bodies first rest at their
  births (age 0), then every live row ages by `ticks`; age 6000 retires its
  remaining units. Returns the containers with the new bodies (`:unchanged` when
  nothing is alive).
  """
  def advance(cs, key, ticks) when is_integer(ticks) and ticks > 0 do
    births = CookingOrbs.owned_records(cs)
    resting = Map.drop(births, Map.keys(cs.orb_bodies.awards))

    with {:ok, cs} <- rest(cs, key, resting) do
      revision = cs.orb_bodies.revision + 1

      {awards, changed} =
        Enum.map_reduce(cs.orb_bodies.awards, false, fn {id, rows}, changed ->
          {rows, changed} =
            Enum.map_reduce(rows, changed, fn {uuid, row}, changed ->
              left = births[id][uuid].count - consumed(cs, uuid) - row.expired

              if left > 0 and row.expired == 0 do
                age = min(row.age + ticks, 6000)

                {{uuid,
                  %{
                    row
                    | revision: revision,
                      age: age,
                      expired: if(age == 6000, do: left, else: 0)
                  }}, true}
              else
                {{uuid, row}, changed}
              end
            end)

          {{id, Map.new(rows)}, changed}
        end)

      cond do
        changed -> apply_proposal(cs, key, %{revision: revision, awards: Map.new(awards)})
        map_size(resting) > 0 -> {:ok, cs}
        true -> {:ok, :unchanged}
      end
    end
  end

  @doc "The oldest live body's age (0 without bodies): ticks left until an expiry."
  def oldest(cs) do
    for {_, rows} <- cs.orb_bodies.awards, {_, row} <- rows, row.expired == 0, reduce: 0 do
      age -> max(age, row.age)
    end
  end

  defp rest(cs, _key, resting) when map_size(resting) == 0, do: {:ok, cs}

  defp rest(cs, key, resting) do
    revision = cs.orb_bodies.revision + 1

    rows =
      Map.new(resting, fn {id, births} ->
        {id,
         Map.new(births, fn {uuid, birth} ->
           {uuid,
            %{
              position: doubles(birth.position),
              velocity: {0.0, 0.0, 0.0},
              revision: revision,
              age: 0,
              on_ground: false,
              no_gravity: false,
              expired: 0
            }}
         end)}
      end)

    with {:ok, cs} <-
           apply_proposal(cs, key, %{
             revision: revision,
             awards: Map.merge(cs.orb_bodies.awards, rows)
           }),
         do: {:ok, cs}
  end

  defp apply_proposal(cs, key, bodies) do
    with {:ok, proposal} <- propose(cs, key, bodies),
         {:ok, next, :applied} <- install(cs, key, proposal),
         do: {:ok, next}
  end

  @doc "Rebase only body state after its read fence matches. Call on a bounded worker before durable owner commit."
  def install(
        cs,
        key,
        %{expected: expected, bodies: %{revision: revision, awards: awards} = bodies} = proposal
      )
      when map_size(proposal) == 2 and map_size(bodies) == 2 and is_map(awards) and
             map_size(awards) <= 256 and is_integer(revision) and revision in 0..@max do
    cond do
      not Enum.all?(awards, fn {_, rows} -> is_map(rows) and map_size(rows) <= 11 end) ->
        invalid()

      cs.orb_bodies === bodies ->
        {:ok, cs, :already_applied}

      fence(cs) != expected ->
        {:error, :stale_orb_body_proposal}

      not transition?(cs, bodies) ->
        invalid()

      true ->
        next = %{cs | orb_bodies: bodies}

        case Containers.encode(key, next) do
          {:ok, _} -> {:ok, next, :applied}
          _ -> {:error, :orb_body_capacity_or_state}
        end
    end
  rescue
    _ -> invalid()
  end

  def install(_, _, _), do: invalid()

  defp propose(cs, key, bodies) do
    proposal = %{expected: fence(cs), bodies: bodies}
    with {:ok, _, :applied} <- install(cs, key, proposal), do: {:ok, proposal}
  end

  defp transition?(cs, next) do
    previous = cs.orb_bodies
    births = CookingOrbs.owned_records(cs)

    next.revision == previous.revision + 1 and
      Enum.all?(previous.awards, fn {id, rows} ->
        Map.has_key?(next.awards, id) and
          Enum.all?(rows, fn {uuid, old} ->
            case next.awards[id][uuid] do
              ^old ->
                true

              row when is_map(row) ->
                left = births[id][uuid].count - consumed(cs, uuid) - old.expired

                left > 0 and old.expired == 0 and row.revision == next.revision and
                  row.age > old.age and row.no_gravity == old.no_gravity and
                  row.expired == if(row.age == 6000, do: left, else: 0)

              _ ->
                false
            end
          end)
      end) and
      Enum.all?(next.awards, fn {id, rows} ->
        Map.has_key?(previous.awards, id) or
          Enum.all?(rows, fn {_, row} ->
            row.revision == next.revision and row.age == 0 and row.expired == 0 and
              row.on_ground == false and row.no_gravity == false
          end)
      end)
  end

  @doc "Current remaining bodies. Missing rows inside an initialized marker fail closed."
  def project(cs) do
    Map.new(CookingOrbs.owned_records(cs), fn {id, births} ->
      rows =
        for {uuid, birth} <- births,
            record = effective(cs, id, uuid, birth),
            record != nil,
            into: %{},
            do: {uuid, record}

      {id, rows}
    end)
  end

  def fetch(cs, uuid) do
    Enum.find_value(CookingOrbs.owned_records(cs), fn {id, births} ->
      case births[uuid] do
        nil -> nil
        birth -> effective(cs, id, uuid, birth)
      end
    end)
  end

  defp effective(cs, id, uuid, birth) do
    row =
      case Map.fetch(cs.orb_bodies.awards, id) do
        :error -> %{position: birth.position, expired: 0}
        {:ok, rows} -> Map.get(rows, uuid)
      end

    if row do
      count = birth.count - consumed(cs, uuid) - row.expired
      if count > 0, do: %{birth | count: count, position: row.position}
    end
  end

  def encode(%{revision: revision, awards: awards} = state, key, cs) when map_size(state) == 2 do
    true = is_map(awards) and map_size(awards) <= 256
    true = is_integer(revision) and revision in 0..@max and revision >= map_size(awards)
    true = revision == 0 == (map_size(awards) == 0)
    births = if map_size(awards) == 0, do: %{}, else: CookingOrbs.owned_records(cs)

    parts =
      Enum.map(Enum.sort(awards), fn {<<_::256>> = id, rows} ->
        expected = Map.fetch!(births, id)

        true =
          is_map(rows) and map_size(rows) <= 11 and
            MapSet.new(Map.keys(rows)) == MapSet.new(Map.keys(expected))

        data =
          Enum.map(Enum.sort(rows), fn {<<_::128>> = uuid, row} ->
            %{
              revision: rev,
              position: {x, y, z},
              velocity: {vx, vy, vz},
              age: age,
              on_ground: ground,
              no_gravity: gravity,
              expired: expired
            } = row

            true = map_size(row) == 7 and is_integer(rev) and rev in 1..revision
            true = Items.valid_position?(row.position) and owned?(key, row.position)

            true =
              Enum.all?([x, y, z, vx, vy, vz], &is_float/1) and
                Enum.all?([vx, vy, vz], &(abs(&1) <= 64))

            true =
              is_integer(age) and age in -32768..6000 and is_boolean(ground) and
                is_boolean(gravity)

            left = expected[uuid].count - consumed(cs, uuid)
            true = is_integer(expired) and expired >= 0 and expired <= left
            true = if(age == 6000, do: expired > 0 and expired == left, else: expired == 0)

            <<uuid::binary, rev::64, x::float-64, y::float-64, z::float-64, vx::float-64,
              vy::float-64, vz::float-64, age::signed-32, 0::6, if(ground, do: 1, else: 0)::1,
              if(gravity, do: 1, else: 0)::1, expired::32>>
          end)

        [<<id::binary, map_size(rows)>>, data]
      end)

    bytes = IO.iodata_to_binary([<<revision::64, map_size(awards)::16>>, parts])
    true = byte_size(bytes) <= @max_bytes
    {:ok, bytes}
  rescue
    _ -> invalid()
  end

  def encode(_, _, _), do: invalid()

  def decode(bytes, key, cs) when is_binary(bytes) and byte_size(bytes) in 10..@max_bytes do
    <<revision::64, count::16, body::binary>> = bytes
    true = count <= 256
    {awards, <<>>} = take_awards(body, count, %{})
    state = %{revision: revision, awards: awards}
    {:ok, ^bytes} = encode(state, key, cs)
    {:ok, state}
  rescue
    _ -> invalid()
  end

  def decode(_, _, _), do: invalid()
  defp take_awards(body, 0, acc), do: {acc, body}

  defp take_awards(<<id::binary-size(32), count, body::binary>>, n, acc) when count <= 11 do
    false = Map.has_key?(acc, id)
    {rows, rest} = take_rows(body, count, %{})
    take_awards(rest, n - 1, Map.put(acc, id, rows))
  end

  defp take_rows(body, 0, acc), do: {acc, body}

  defp take_rows(
         <<uuid::binary-size(16), rev::64, x::float-64, y::float-64, z::float-64, vx::float-64,
           vy::float-64, vz::float-64, age::signed-32, 0::6, g::1, n::1, expired::32,
           rest::binary>>,
         count,
         acc
       ) do
    false = Map.has_key?(acc, uuid)

    row = %{
      revision: rev,
      position: {x, y, z},
      velocity: {vx, vy, vz},
      age: age,
      on_ground: g == 1,
      no_gravity: n == 1,
      expired: expired
    }

    take_rows(rest, count - 1, Map.put(acc, uuid, row))
  end

  defp consumed(cs, uuid), do: Map.get(cs.orb_consumption.counts, uuid, 0)
  defp doubles({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}
  defp owned?(key, {x, _, z}), do: Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key
  defp invalid, do: {:error, :invalid_orb_bodies}
end
