defmodule Valimc.Net.Profiler.View do
  @moduledoc false
  # Presentation is pure and bounded. Only expanded branches are grouped; a
  # capture with 4096 unrelated deep stacks never becomes a 200,000-node trie.
  @tabs [
    {"tree", "Call tree"},
    {"flame", "Flame graph"},
    {"hot", "Hot methods"},
    {"processes", "Processes"},
    {"regions", "Region ticks"},
    {"memory", "Memory / ETS"},
    {"counters", "Counters"},
    {"health", "Health"}
  ]
  def tabs, do: @tabs

  def groups(data),
    do: data |> Map.get(:stacks, []) |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

  def stacks(data, query, group) do
    Enum.filter(Map.get(data, :stacks, []), fn s ->
      (group == "" or s.name == group) and matches?([s.name | s.frames], query)
    end)
    |> Enum.map(&%{path: [&1.name | &1.frames], count: &1.count})
  end

  def tree(stacks, expanded) do
    total = Enum.sum(Enum.map(stacks, & &1.count))
    {rows, _} = branches(stacks, [], total, expanded, 1000)
    rows
  end

  defp branches(_, _, _, _, 0), do: {[], 0}

  defp branches(stacks, prefix, total, expanded, left) do
    Enum.reduce_while(children(stacks, prefix), {[], left}, fn node, {acc, left} ->
      if left == 0 do
        {:halt, {acc, left}}
      else
        open = MapSet.member?(expanded, node.id)

        row =
          Map.merge(Map.delete(node, :items), %{
            depth: length(prefix),
            percent: 100 * node.count / max(total, 1),
            open: open
          })

        {descendants, left} =
          if open,
            do: branches(node.items, node.path, total, expanded, left - 1),
            else: {[], left - 1}

        {:cont, {acc ++ [row | descendants], left}}
      end
    end)
  end

  defp children(stacks, prefix) do
    depth = length(prefix)

    stacks
    |> Enum.filter(&(length(&1.path) > depth))
    |> Enum.group_by(&Enum.at(&1.path, depth))
    |> Enum.map(fn {name, items} ->
      path = prefix ++ [name]

      %{
        id: key(path),
        name: name,
        path: path,
        count: Enum.sum(Enum.map(items, & &1.count)),
        children: Enum.any?(items, &(length(&1.path) > depth + 1)),
        items: items
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.name})
  end

  defp key(path),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(path)) |> Base.encode16(case: :lower)

  def flame(stacks, zoom) do
    prefix = zoom || []
    selected = Enum.filter(stacks, &(Enum.take(&1.path, length(prefix)) == prefix))
    count = Enum.sum(Enum.map(selected, & &1.count))

    base = %{
      id: key(prefix),
      path: prefix,
      name: List.last(prefix) || "All observed stacks",
      count: count
    }

    {rows, _} = paint(selected, base, 0.0, 0, 1200.0, count, 2000)
    rows
  end

  defp paint(_, _, _, _, width, _, left) when width < 2 or left == 0, do: {[], left}
  defp paint(_, _, _, depth, _, _, left) when depth > 24, do: {[], left}

  defp paint(stacks, node, x, depth, width, total, left) do
    row =
      Map.merge(Map.delete(node, :items), %{
        x: x,
        y: depth * 25,
        width: width,
        percent: node.count * 100 / max(total, 1)
      })

    {rows, _, left} =
      Enum.reduce(children(stacks, node.path), {[row], x, left - 1}, fn child, {acc, x, left} ->
        w = width * child.count / max(node.count, 1)
        {rows, left} = paint(child.items, child, x, depth + 1, w, total, left)
        {acc ++ rows, x + w, left}
      end)

    {rows, left}
  end

  def table(data, tab, query, group, sort, direction) do
    {columns, rows} = rows(data, tab, query, group)

    sort =
      Enum.find_value(columns, default_sort(tab, columns), fn {key, _, _} ->
        if Atom.to_string(key) == sort, do: key
      end)

    rows = Enum.filter(rows, &matches?(Map.values(&1), query))
    rows = Enum.sort_by(rows, &Map.get(&1, sort, 0), direction)
    {columns, Enum.take(rows, 500), length(rows)}
  end

  defp default_sort("hot", _), do: :samples
  defp default_sort("processes", _), do: :reductions
  defp default_sort("regions", _), do: :last_ms
  defp default_sort("memory", _), do: :bytes
  defp default_sort(_, columns), do: elem(hd(columns), 0)

  defp rows(data, "processes", _, group) do
    {[
       {:name, "Process group", :text},
       {:pid, "PID", :text},
       {:reductions, "Reductions", :number},
       {:memory, "Memory", :memory},
       {:mailbox, "Mailbox", :number},
       {:status, "Status", :text}
     ], Enum.filter(Map.get(data, :processes, []), &(group == "" or &1.name == group))}
  end

  defp rows(data, "regions", _, _) do
    {[
       {:pid, "Owner PID", :text},
       {:tps, "Interval TPS", :number},
       {:mean_ms, "Interval mean (ms)", :number},
       {:last_ms, "Latest (ms)", :number},
       {:max_ms, "Lifetime max (ms)", :number},
       {:late_ms, "Lateness (ms)", :number},
       {:age_ms, "Age (ms)", :number}
     ], data.health.owners}
  end

  defp rows(data, "memory", _, _) do
    {[
       {:name, "Memory category / ETS table", :text},
       {:bytes, "Memory", :memory},
       {:size, "Objects", :number}
     ],
     Enum.map(data.health.memory, fn {k, v} -> %{name: Atom.to_string(k), bytes: v, size: nil} end) ++
       data.health.ets}
  end

  defp rows(data, "counters", _, _) do
    {[{:name, "Counter / gauge", :text}, {:value, "Value", :number}],
     Enum.map(data.health.counters, fn {k, v} -> %{name: to_string(k), value: v} end)}
  end

  defp rows(data, "health", _, _) do
    h = data.health

    {[{:name, "Metric", :text}, {:value, "Value", :number}],
     [
       %{name: "World clock TPS (separate)", value: Map.get(h, :clock_tps, h.tps)},
       %{name: "Normal scheduler utilization (%)", value: h.scheduler.normal},
       %{name: "Dirty CPU scheduler utilization (%)", value: h.scheduler.dirty_cpu},
       %{name: "Dirty IO scheduler utilization (%)", value: h.scheduler.dirty_io},
       %{name: "GC collections since boot", value: h.gc.collections},
       %{name: "GC reclaimed words since boot", value: h.gc.reclaimed_words},
       %{name: "Processes", value: h.processes},
       %{name: "Online schedulers", value: h.schedulers}
     ]}
  end

  defp rows(data, "hot", query, group) do
    stacks = stacks(data, query, group)
    total = Enum.sum(Enum.map(stacks, & &1.count))

    methods =
      Enum.reduce(stacks, %{}, fn s, acc ->
        for name <- s.path |> tl() |> Enum.uniq(), reduce: acc do
          acc ->
            if map_size(acc) >= 8192 and not Map.has_key?(acc, name) do
              acc
            else
              Map.update(
                acc,
                name,
                %{
                  name: name,
                  samples: s.count,
                  self: if(name == List.last(s.path), do: s.count, else: 0)
                },
                &%{
                  &1
                  | samples: &1.samples + s.count,
                    self: &1.self + if(name == List.last(s.path), do: s.count, else: 0)
                }
              )
            end
        end
      end)

    {[
       {:name, "Function", :text},
       {:samples, "Inclusive samples", :number},
       {:self, "Leaf samples", :number},
       {:percent, "Selected stacks", :percent}
     ], Enum.map(methods, fn {_, r} -> Map.put(r, :percent, r.samples * 100 / max(total, 1)) end)}
  end

  def matches?(_, ""), do: true

  def matches?(values, query),
    do:
      Enum.any?(values, &String.contains?(String.downcase(to_string(&1)), String.downcase(query)))

  def format(nil, _), do: "—"
  def format(n, :memory), do: format(n / 1_048_576, :number) <> " MB"
  def format(n, :percent), do: format(n, :number) <> "%"
  def format(n, :number) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  def format(n, _), do: to_string(n)

  def tps_title(%{health: %{tps_source: "simulation"}}), do: "Simulation TPS"
  def tps_title(_), do: "Clock TPS (legacy)"

  def tps_caption(%{health: %{tps_source: "simulation", tick_state: %{frozen: true}}}),
    do: "Frozen · completed region ticks"

  def tps_caption(%{health: %{tps_source: "simulation"}}),
    do: "Slowest region · completed ticks"

  def tps_caption(_), do: "Simulation history was not recorded"

  def chart_max(data, metric \\ :tps) do
    Enum.reduce(Map.get(data, :history, []), if(metric == :tps, do: 20.0, else: 50.0), fn p,
                                                                                          max ->
      case chart_value(p, metric) do
        n when is_number(n) -> max(n, max)
        _ -> max
      end
    end)
  end

  def chart(data, metric \\ :tps) do
    points = Map.get(data, :history, [])
    maximum = chart_max(data, metric)
    first = if points == [], do: 0, else: hd(points).at
    duration = if points == [], do: 1, else: max(List.last(points).at - first, 1)

    points
    |> Enum.map_reduce(false, fn p, drawing ->
      case chart_value(p, metric) do
        n when is_number(n) ->
          {"#{if drawing, do: "L", else: "M"}#{(p.at - first) * 1200 / duration},#{170 - n / maximum * 150}",
           true}

        _ ->
          {"", false}
      end
    end)
    |> elem(0)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp chart_value(p, :tps), do: Map.get(p, :tps)
  defp chart_value(p, :mspt), do: get_in(p, [:mspt, :p95])
end
