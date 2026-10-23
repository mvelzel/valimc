# Differential check of hoppers (VMC-049a: `Valimc.World.Hoppers` over
# `Valimc.Blocks.ItemTransfer`) against HopperOracle's scenes: per game tick, every
# container's slots, each hopper's cooldown, each furnace's timers and every item entity's
# count. The cells come from vanilla's writes (the redstone blocks the scenes place and the
# hoppers' `enabled` they switch, which the block rules' own stage checks); furnaces step
# after the hoppers (`Valimc.Blocks.Cooking.step/2`), as they were created after them and
# as ValiMC's cooking phase follows its hopper phase.
alias Valimc.Blocks.{Cooking, CookingBlocks, Machine}
alias Valimc.Protocol.ItemStack
alias Valimc.World.Hoppers

[scenes_file] = System.argv()
scenes = JSON.decode!(File.read!(scenes_file))

stack = fn
  nil -> nil
  [name, count] -> ItemStack.new(name, count)
end

slots = fn list -> list |> Enum.map(stack) |> List.to_tuple() end

entry = fn [x, y, z, list | rest], block, order ->
  cond do
    CookingBlocks.kind(block) ->
      [left, total, progress, cook_total] = rest

      %{
        kind: CookingBlocks.kind(block),
        revision: 1,
        recipes: %{},
        cooking: %Cooking{
          slots: slots.(list),
          burn_left: left,
          burn_total: total,
          progress: progress,
          total: cook_total
        }
      }

    kind = Machine.kind(block) ->
      cooldown = if kind == :hopper, do: hd(rest), else: -1
      %{kind: kind, slots: slots.(list), cooldown: cooldown, order: order, revision: order}

    true ->
      %{rows: 3, slots: slots.(list), revision: 1}
  end
  |> then(&{{x, y, z}, &1})
end

# What the oracle records of an entry, to compare.
view = fn
  %{cooking: c} -> {Tuple.to_list(c.slots), [c.burn_left, c.burn_total, c.progress, c.total]}
  %{kind: :hopper, slots: s, cooldown: cooldown} -> {Tuple.to_list(s), [cooldown]}
  %{slots: s} -> {Tuple.to_list(s), []}
end

recorded = fn [_, _, _, list | rest] -> {Enum.map(list, stack), rest} end

compare = fn scene ->
  cells = Map.new(scene["blocks"], fn [x, y, z, s] -> {{x, y, z}, s} end)
  order = for [x, y, z] <- scene["order"], do: {x, y, z}

  entries =
    scene["containers"]
    |> Enum.with_index(1)
    |> Map.new(fn {[x, y, z | _] = row, i} -> entry.(row, cells[{x, y, z}], i) end)

  vanilla =
    Map.new(scene["containers"], fn [x, y, z | _] = row -> {{x, y, z}, recorded.(row)} end)

  items =
    scene["items"]
    |> Enum.with_index()
    |> Enum.map(fn {[x, y, z, s], i} -> %{id: i, x: x, y: y, z: z, stack: stack.(s)} end)

  counts = Map.new(items, &{&1.id, &1.stack.count})
  steps = Map.new(scene["steps"], &{&1["t"], &1})
  hoppers = Enum.filter(order, &(Machine.kind(cells[&1]) == :hopper))
  furnaces = Enum.filter(order, &CookingBlocks.kind(cells[&1]))

  Enum.reduce_while(0..239, {cells, entries, items, %{}, vanilla, counts}, fn t,
                                                                              {cells, entries,
                                                                               items, ticked,
                                                                               vanilla, counts} ->
    step = Map.get(steps, t, %{"writes" => [], "containers" => [], "items" => []})

    cells =
      Enum.reduce(step["writes"], cells, fn [x, y, z, s], acc -> Map.put(acc, {x, y, z}, s) end)

    result =
      Hoppers.tick(%{
        tick: t,
        entries: entries,
        foreign: %{},
        block: &Map.get(cells, &1, 0),
        items: items,
        hoppers: hoppers,
        ticked: ticked
      })

    items =
      Enum.flat_map(items, fn item ->
        case Map.fetch(result.items, item.id) do
          {:ok, nil} -> []
          {:ok, rest} -> [%{item | stack: rest}]
          :error -> [item]
        end
      end)

    entries =
      Enum.reduce(furnaces, result.entries, fn position, acc ->
        furnace = acc[position]
        {:ok, cooking, _events} = Cooking.step(furnace.cooking, cells[position])
        Map.put(acc, position, %{furnace | cooking: cooking})
      end)

    vanilla =
      Enum.reduce(step["containers"], vanilla, fn [x, y, z | _] = row, acc ->
        Map.put(acc, {x, y, z}, recorded.(row))
      end)

    counts = Enum.reduce(step["items"], counts, fn [i, n], acc -> Map.put(acc, i, n) end)

    ours_counts =
      Map.new(Map.keys(counts), fn i ->
        {i, Enum.find_value(items, 0, &(&1.id == i && &1.stack.count))}
      end)

    mismatch =
      Enum.find(order, fn position -> view.(entries[position]) != vanilla[position] end)

    cond do
      mismatch != nil ->
        {:halt, {:mismatch, t, mismatch, vanilla[mismatch], view.(entries[mismatch])}}

      ours_counts != counts ->
        {:halt, {:mismatch, t, :items, counts, ours_counts}}

      true ->
        {:cont, {cells, entries, items, result.ticked, vanilla, counts}}
    end
  end)
  |> case do
    {:mismatch, _, _, _, _} = mismatch -> mismatch
    _ -> :ok
  end
end

results = Enum.map(scenes, compare)
failures = Enum.reject(Enum.with_index(results), fn {r, _} -> r == :ok end)

case failures do
  [] ->
    IO.puts("PASS: #{length(scenes)} hopper scenes match vanilla tick by tick")

  [{first, index} | _] ->
    IO.puts(
      "FAIL: #{length(failures)} of #{length(scenes)} hopper scenes differ; scene #{index}:"
    )

    IO.inspect(first, limit: :infinity)
    System.halt(1)
end
