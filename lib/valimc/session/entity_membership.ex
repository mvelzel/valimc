defmodule Valimc.Session.EntityMembership do
  @moduledoc """
  Which published entities a connection observes (VMC-081i): its desired
  views, kept on change as vanilla's `ChunkMap.TrackedEntity.updatePlayer`
  is, not recomputed every tick.

  A chunk's row is filtered (`visible`: in tracking range, a player shown)
  only when its stamp changed; while the observer's key (its position, view
  and what decides which players it sees) stays, the desired views change
  by the rows that changed, and the ids they held or hold are what an
  observer re-examines (`touched`). A new key filters every row again, and
  so does a row set that names one entity twice (a handoff publishes it in
  two sections) or one beyond `Observer.max_visible/0`: then every id is
  touched (`:all`) and the chunk order and the newer ownership generation
  decide, as `Valimc.World.EntityViews.select/1` does.
  """
  alias Valimc.Entity.Observer
  alias Valimc.World.EntityViews

  defstruct key: nil, chunks: %{}, desired: %{}, count: 0

  @doc """
  The observer's desired views over `rows` (`EntityViews.rows/4`) for `key`:
  `{membership, desired, touched}`, `touched` the ids whose membership or
  view may have changed, or `:all`.
  """
  def update(m, rows, key, visible) do
    if key != m.key, do: full(rows, key, visible), else: changes(m, rows, key, visible)
  end

  defp full(rows, key, visible) do
    chunks =
      Map.new(rows, fn {chunk, {stamp, views}} -> {chunk, filter(stamp, views, visible)} end)

    whole(chunks, key)
  end

  defp whole(chunks, key) do
    desired = EntityViews.select(Map.new(chunks, fn {c, {s, v, _, _}} -> {c, {s, v}} end))
    count = Enum.reduce(chunks, 0, fn {_, {_, _, n, _}}, acc -> acc + n end)
    {%__MODULE__{key: key, chunks: chunks, desired: desired, count: count}, desired, :all}
  end

  # A row holding a player is filtered every pass: whether a player is shown
  # (online, a spectator) is not in its row alone.
  defp filter(stamp, views, visible) do
    kept = for {_, view} = entry <- views, visible.(view), do: entry
    {stamp, kept, length(kept), Enum.any?(views, &match?({_, %{kind: :player}}, &1))}
  end

  defp changes(m, rows, key, visible) do
    {chunks, old, new, count} =
      Enum.reduce(rows, {m.chunks, [], [], m.count}, fn {chunk, {stamp, views}}, acc ->
        case m.chunks do
          %{^chunk => {^stamp, _, _, false}} ->
            acc

          _ ->
            {chunks, old, new, count} = acc
            {_, kept, n, _} = entry = filter(stamp, views, visible)

            case m.chunks do
              %{^chunk => {_, ^kept, _, _}} ->
                {Map.put(chunks, chunk, entry), old, new, count}

              %{^chunk => {_, before, before_n, _}} ->
                {Map.put(chunks, chunk, entry), [before | old], [kept | new],
                 count - before_n + n}

              _ ->
                {Map.put(chunks, chunk, entry), old, [kept | new], count + n}
            end
        end
      end)

    # Rows gone from the candidates.
    {chunks, old, count} =
      if map_size(chunks) == map_size(rows) do
        {chunks, old, count}
      else
        Enum.reduce(m.chunks, {chunks, old, count}, fn {chunk, {_, before, n, _}}, acc ->
          {chunks, old, count} = acc

          if is_map_key(rows, chunk),
            do: acc,
            else: {Map.delete(chunks, chunk), [before | old], count - n}
        end)
      end

    cond do
      old == [] and new == [] ->
        {%{m | chunks: chunks}, m.desired, []}

      count > Observer.max_visible() or m.count != map_size(m.desired) ->
        whole(chunks, key)

      true ->
        dropped = for list <- old, {id, _} <- list, do: id
        added = for list <- new, entry <- list, do: entry
        desired = m.desired |> Map.drop(dropped) |> Map.merge(Map.new(added))

        if map_size(desired) == count do
          touched = dropped ++ Enum.map(added, &elem(&1, 0))
          {%{m | chunks: chunks, desired: desired, count: count}, desired, touched}
        else
          # One entity in two rows: chunk order and generations decide.
          whole(chunks, key)
        end
    end
  end
end
