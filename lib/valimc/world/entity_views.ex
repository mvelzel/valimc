defmodule Valimc.World.EntityViews do
  @moduledoc "Bounded observer caches over immutable section publications."
  alias Valimc.Entity.{Observer, Publication}
  alias Valimc.World.Directory

  @doc """
  The entity views of `chunks` in `regions` (at most 64 sections and
  `Observer.max_visible/0` views, in chunk order), with `cache`:
  `{views, cache}`.
  """
  def read(regions, chunks, cache, lookup \\ &Directory.lookup/1) do
    case rows(regions, chunks, cache, lookup) do
      {_, %{views: views} = cache} ->
        {views, cache}

      {rows, cache} ->
        views = select(rows)
        {views, Map.put(cache, :views, views)}
    end
  end

  @doc """
  The published rows of `chunks` in `regions`, `%{chunk => {stamp, views}}`
  (each row's views sorted by id), with `cache`: `{rows, cache}`. Unchanged
  sections and chunks keep their terms, so a reader compares stamps.
  """
  def rows(regions, chunks, cache, lookup \\ &Directory.lookup/1) do
    routes =
      regions
      |> Enum.sort()
      |> Enum.take(64)
      |> Enum.map(&route(&1, lookup))

    case cache do
      %{routes: ^routes, input: ^chunks, rows: rows} ->
        {rows, cache}

      _ ->
        wanted =
          case cache do
            %{input: ^chunks, wanted: wanted} -> wanted
            _ -> chunks |> Enum.sort() |> Enum.take(4096) |> MapSet.new()
          end

        old = Map.get(cache, :sections, %{})

        sections =
          Map.new(routes, fn {key, table, revision} ->
            {key, section(table, revision, old[key])}
          end)

        rows =
          for {_, section} <- sections,
              {chunk, row} <- section.chunks,
              MapSet.member?(wanted, chunk),
              into: %{},
              do: {chunk, row}

        {rows, %{routes: routes, input: chunks, wanted: wanted, sections: sections, rows: rows}}
    end
  end

  defp route(key, lookup) do
    case lookup.(key) do
      {_, _, %{publication: table}} -> {key, table, Publication.revision(table)}
      _ -> {key, nil, nil}
    end
  rescue
    ArgumentError -> {key, nil, nil}
  end

  defp section(nil, _, _), do: %{table: nil, revision: nil, chunks: %{}}

  defp section(table, revision, %{table: table, revision: revision} = cached), do: cached

  defp section(table, revision, cached) do
    old = if cached != nil and cached.table == table, do: cached.chunks, else: %{}
    index = :ets.lookup_element(table, :entity_index, 2, %{})

    chunks =
      Map.new(index, fn {chunk, _} ->
        stamp = :ets.lookup_element(table, {:entities, chunk}, 2, nil)

        value =
          case old do
            %{^chunk => {^stamp, _} = row} ->
              row

            _ ->
              case :ets.lookup(table, {:entities, chunk}) do
                [{_, stamp, views}] -> {stamp, Enum.sort(views)}
                [] -> {nil, []}
              end
          end

        {chunk, value}
      end)

    %{table: table, revision: revision, chunks: chunks}
  rescue
    ArgumentError -> %{table: nil, revision: nil, chunks: %{}}
  end

  @doc """
  The views of `rows` an observer may see: at most `Observer.max_visible/0`,
  in chunk order, the newer ownership generation where two sections publish
  one entity (a handoff).
  """
  def select(rows) do
    limit = Observer.max_visible()

    rows
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(%{}, fn {_, {_, views}}, acc ->
      if map_size(acc) == limit do
        {:halt, acc}
      else
        selected = views |> Enum.take(limit - map_size(acc)) |> Map.new()
        {:cont, Map.merge(acc, selected, &newer/3)}
      end
    end)
  end

  @doc "Of two views of one entity, the one of the newer ownership generation."
  def newer(_, old, view),
    do: if(view.ownership_generation > old.ownership_generation, do: view, else: old)
end
