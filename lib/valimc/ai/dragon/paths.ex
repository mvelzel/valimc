defmodule Valimc.AI.Dragon.Paths do
  @moduledoc """
  The dragon's 24-node arena graph (VMC-045a2). Height is sampled once when
  the arena initializes. Searches retain the native binary heap's tie order
  and closest reachable fallback, including searches with no outer ring.
  """
  import Bitwise
  alias Valimc.AI.Dragon.Facts
  alias Valimc.Data.Float32

  @doc "Build from authoritative MOTION_BLOCKING_NO_LEAVES column heights."
  def graph(height) do
    for {x, offset, z, mask} <- Facts.graph() do
      {{x, max(73, height.(x, z) + offset), z}, mask}
    end
    |> List.to_tuple()
  end

  @doc "Native closest-node selection; nil fight and zero crystals skip the outer ring."
  def closest(graph, {x, y, z}, crystals) do
    position = {floor(x), floor(y), floor(z)}

    {index, _} =
      Enum.reduce(first(crystals)..23, {0, 10_000.0}, fn i, {best, distance} ->
        next = squared(position, at(graph, i))
        if next < distance, do: {i, next}, else: {best, distance}
      end)

    index
  end

  @doc "A path including its start and optional final coordinate, or nil if no progress."
  def find(graph, start, finish, crystals, final \\ nil)
      when start in 0..23 and finish in 0..23 do
    distance = distance(at(graph, start), at(graph, finish))
    nodes = %{start => %{g: 0.0, f: distance, from: nil}}
    search(graph, finish, first(crystals), final, [start], nodes, MapSet.new(), start, start)
  end

  defp search(_graph, _finish, _minimum, _final, [], _nodes, _closed, start, start), do: nil

  defp search(graph, _finish, _minimum, final, [], nodes, _closed, _start, closest),
    do: path(graph, nodes, closest, final)

  defp search(graph, finish, minimum, final, open, nodes, closed, start, closest) do
    {current, open} = pop(open, nodes)

    if current == finish do
      path(graph, nodes, current, final)
    else
      target = at(graph, finish)

      closest =
        if distance(at(graph, current), target) < distance(at(graph, closest), target),
          do: current,
          else: closest

      closed = MapSet.put(closed, current)
      {_, mask} = elem(graph, current)

      {open, nodes} =
        Enum.reduce(minimum..23, {open, nodes}, fn i, {open, nodes} ->
          g = f(nodes[current].g + distance(at(graph, current), at(graph, i)))

          if (mask &&& 1 <<< i) != 0 and not MapSet.member?(closed, i) and
               (not Map.has_key?(nodes, i) or g < nodes[i].g) do
            cost = f(g + distance(at(graph, i), target))
            previous = nodes[i]
            nodes = Map.put(nodes, i, %{g: g, f: cost, from: current})

            open =
              if previous do
                index = Enum.find_index(open, &(&1 == i))
                if cost < previous.f, do: up(open, index, nodes), else: down(open, index, nodes)
              else
                up(open ++ [i], length(open), nodes)
              end

            {open, nodes}
          else
            {open, nodes}
          end
        end)

      search(graph, finish, minimum, final, open, nodes, closed, start, closest)
    end
  end

  defp path(graph, nodes, index, final) do
    result = backtrack(graph, nodes, index, [])
    if final, do: result ++ [final], else: result
  end

  defp backtrack(graph, nodes, index, result) do
    result = [at(graph, index) | result]

    case nodes[index].from do
      nil -> result
      previous -> backtrack(graph, nodes, previous, result)
    end
  end

  # At most 24 entries; strict comparisons keep insertion ties and choose the
  # right child on equal costs, as the native path queue does.
  defp pop([first], _nodes), do: {first, []}

  defp pop([first | _] = open, nodes),
    do: {first, down(List.replace_at(Enum.drop(open, -1), 0, List.last(open)), 0, nodes)}

  defp up(open, 0, _nodes), do: open

  defp up(open, index, nodes) do
    parent = div(index - 1, 2)

    if cost(open, index, nodes) < cost(open, parent, nodes),
      do: up(swap(open, index, parent), parent, nodes),
      else: open
  end

  defp down(open, index, nodes) do
    left = index * 2 + 1
    right = left + 1

    cond do
      left >= length(open) ->
        open

      true ->
        child =
          if right < length(open) and cost(open, right, nodes) <= cost(open, left, nodes),
            do: right,
            else: left

        if cost(open, child, nodes) < cost(open, index, nodes),
          do: down(swap(open, index, child), child, nodes),
          else: open
    end
  end

  defp cost(open, index, nodes), do: nodes[Enum.at(open, index)].f

  defp swap(open, a, b),
    do: open |> List.replace_at(a, Enum.at(open, b)) |> List.replace_at(b, Enum.at(open, a))

  defp first(crystals) when crystals in [nil, 0], do: 12
  defp first(_crystals), do: 0
  defp at(graph, index), do: elem(elem(graph, index), 0)
  defp distance(a, b), do: f(:math.sqrt(squared(a, b)))

  defp squared({x, y, z}, {a, b, c}),
    do: f(f(f((x - a) * (x - a)) + f((y - b) * (y - b))) + f((z - c) * (z - c)))

  defp f(v), do: Float32.round(v)
end
