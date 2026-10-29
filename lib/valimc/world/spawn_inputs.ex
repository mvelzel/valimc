defmodule Valimc.World.SpawnInputs do
  @moduledoc "Reusable spawning rows from authoritative section state, with no observation cache."
  alias Valimc.Data.{EntityTypes, Grid}

  def prepare(sections, previous \\ %{}) do
    Enum.reduce(sections, {[], [], [], %{}}, fn {key, resource}, {mobs, bodies, chunks, cached} ->
      entries = resource.entities.store.entries
      ticking = resource.tickets.simulated
      rows = section(entries, ticking, previous[key])

      {rows.mobs ++ mobs, rows.bodies ++ bodies, rows.chunks ++ chunks,
       Map.put(cached, key, rows)}
    end)
  end

  @doc """
  The sections (`id => key`) of the entities `ids` in the `prepared` rows;
  only a plan that discards or resets mobs needs them, so they are not kept
  for every loaded entity each tick.
  """
  def owners(_prepared, []), do: %{}

  def owners(prepared, ids) do
    wanted = MapSet.new(ids)

    for {key, rows} <- prepared,
        id <- rows.ids,
        MapSet.member?(wanted, id),
        into: %{},
        do: {id, key}
  end

  defp section(entries, ticking, %{entries: entries, ticking: ticking} = cached), do: cached

  defp section(entries, ticking, _previous) do
    {mobs, bodies} =
      Enum.reduce(entries, {[], []}, fn
        {id, %{kind: :mob, entity: e, body: %{type: type, mob: mob}} = entry}, {mobs, bodies} ->
          alive = Valimc.Entity.Mob.alive?(mob)

          flags =
            if(mob.persistent or Map.get(entry.body.data, :from_bucket, false), do: 1, else: 0) +
              if(alive and MapSet.member?(ticking, Grid.chunk_key(e.x, e.z)), do: 2, else: 0)

          row =
            {id, EntityTypes.id(type), {e.x, e.y, e.z}, flags, Map.get(entry, :idle, 0),
             Map.get(entry, :lived, 0)}

          {[row | mobs], [box(type, e) | bodies]}

        {_, %{kind: :object, entity: e, body: %{type: type}}}, {mobs, bodies} ->
          {mobs, [box(type, e) | bodies]}

        _, acc ->
          acc
      end)

    %{
      entries: entries,
      ticking: ticking,
      mobs: mobs,
      bodies: bodies,
      chunks: MapSet.to_list(ticking),
      ids: Map.keys(entries)
    }
  end

  defp box(type, %{x: x, y: y, z: z}) do
    %{width: w, height: h} = EntityTypes.fetch(type)
    {x - w / 2, y, z - w / 2, x + w / 2, y + h, z + w / 2}
  end

  def distribute(plan, ids, owners, field) when field in [1, 2] do
    Enum.reduce(ids, plan, fn id, acc ->
      case owners[id] do
        nil ->
          acc

        key ->
          Map.update(acc, key, put_elem({[], [], [], []}, field, [id]), fn row ->
            put_elem(row, field, [id | elem(row, field)])
          end)
      end
    end)
  end
end
