defmodule Valimc.World.EntityViews do
  @moduledoc "Bounded observer caches over immutable section publications."
  alias Valimc.Entity.{Observer, Publication}
  alias Valimc.World.Directory

  def read(regions, chunks, cache, lookup \\ &Directory.lookup/1) do
    routes =
      regions
      |> Enum.sort()
      |> Enum.take(64)
      |> Enum.map(&route(&1, lookup))

    case cache do
      %{routes: ^routes, input: ^chunks, views: views} ->
        {views, cache}

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

        views = select(sections, wanted)

        {views,
         %{routes: routes, input: chunks, wanted: wanted, sections: sections, views: views}}
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
      Map.new(index, fn {chunk, _hash} ->
        stamp = :ets.lookup_element(table, {:entities, chunk}, 2, nil)

        value =
          case old do
            %{^chunk => {^stamp, views}} ->
              {stamp, views}

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

  defp select(sections, wanted) do
    limit = Observer.max_visible()

    sections
    |> Enum.flat_map(fn {_, section} ->
      for {chunk, {_, views}} <- section.chunks,
          MapSet.member?(wanted, chunk),
          do: {chunk, views}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(%{}, fn {_, views}, acc ->
      if map_size(acc) == limit do
        {:halt, acc}
      else
        selected = views |> Enum.take(limit - map_size(acc)) |> Map.new()
        {:cont, Map.merge(acc, selected, &newer/3)}
      end
    end)
  end

  defp newer(_, old, view),
    do: if(view.ownership_generation > old.ownership_generation, do: view, else: old)
end
