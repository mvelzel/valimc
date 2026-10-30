defmodule Valimc.ViewStreamingTest do
  # VMC-081k: the incremental view bookkeeping equals a recompute from scratch.
  use ExUnit.Case, async: true
  alias Valimc.Data.Grid
  alias Valimc.Player.ChunkView
  alias Valimc.Session.{PendingChunks, ViewWants}

  # The scan of the bounding box that `ChunkView.difference/2` replaced.
  defp scanned(from, to, contains?) do
    {x0, z0, x1, z1} = {-80, -80, 80, 80}

    for x <- x0..x1, z <- z0..z1, reduce: {[], []} do
      {entering, leaving} ->
        case {contains?.(from, {x, z}), contains?.(to, {x, z})} do
          {false, true} -> {[{x, z} | entering], leaving}
          {true, false} -> {entering, [{x, z} | leaving]}
          _ -> {entering, leaving}
        end
    end
  end

  defp square?(nil, _), do: false
  defp square?({{cx, cz}, r}, {x, z}), do: abs(x - cx) <= r and abs(z - cz) <= r

  defp views(seed, count) do
    :rand.seed(:exsss, {seed, 2, 3})

    Enum.scan(1..count, {{0, 0}, 12}, fn _, {{x, z}, d} ->
      case :rand.uniform(10) do
        1 -> {{x + :rand.uniform(81) - 41, z + :rand.uniform(81) - 41}, d}
        2 -> {{x, z}, Enum.random(2..32)}
        _ -> {{x + :rand.uniform(3) - 2, z + :rand.uniform(3) - 2}, d}
      end
    end)
  end

  test "differences visit columns and give the box scan's chunks in its order" do
    near? = fn
      nil -> true
      {{x, z}, _} -> abs(x) <= 40 and abs(z) <= 40
    end

    for {from, to} <- Enum.zip([nil | views(1, 80)], views(1, 80)), near?.(from), near?.(to) do
      {entering, leaving} = scanned(from, to, &ChunkView.contains?/2)

      # Overlapping views give the scan's very lists; others every chunk of
      # each view, nearest first.
      case ChunkView.difference(from, to) do
        {^entering, ^leaving} ->
          :ok

        {e, l} ->
          assert {e, l} == {ChunkView.chunks(to), ChunkView.chunks(from)}
          assert {MapSet.new(e), MapSet.new(l)} == {MapSet.new(entering), MapSet.new(leaving)}

          with {{fx, fz}, fd} <- from do
            {{tx, tz}, td} = to
            assert abs(fx - tx) > fd + td + 2 or abs(fz - tz) > fd + td + 2
          end
      end
    end

    squares = [nil, {{0, 0}, 10}, {{1, 0}, 10}, {{1, 1}, 10}, {{3, -2}, 6}, {{40, 40}, 10}, nil]

    for {from, to} <- Enum.zip(squares, tl(squares)) do
      assert ChunkView.square_difference(from, to) == scanned(from, to, &square?/2)
    end
  end

  # The sets `want_chunks` built from the whole view before VMC-081k.
  defp recomputed(view, {{cx, cz}, reach}, arena) do
    local = for x <- (cx - reach)..(cx + reach), z <- (cz - reach)..(cz + reach), do: {x, z}
    simulation = MapSet.new(local ++ arena)

    view
    |> ChunkView.chunks()
    |> Enum.concat(Enum.reject(simulation, &ChunkView.contains?(view, &1)))
    |> Enum.group_by(&Grid.region_key/1)
    |> Map.new(fn {key, chunks} ->
      {key,
       {MapSet.new(chunks), MapSet.new(Enum.filter(chunks, &MapSet.member?(simulation, &1)))}}
    end)
  end

  test "a walk of view changes wants what a recompute wants" do
    arena = [{-1, -1}, {0, 0}, {5, 5}, {9, -3}]

    Enum.reduce(views(2, 120), %ViewWants{}, fn {center, _} = view, wants ->
      # The simulation reach may exceed the view's distance; the arena comes and goes.
      reach = Enum.random([4, 10])
      arena = if :rand.uniform(3) == 1, do: arena, else: []
      dimension = if :rand.uniform(15) == 1, do: :the_nether, else: :overworld
      wants = ViewWants.update(wants, dimension, view, {center, reach}, arena)
      assert wants.sections == recomputed(view, {center, reach}, arena)
      wants
    end)
  end

  defp table(generated, absent) do
    table = :ets.new(:publication, [:set, :public])
    :ets.insert(table, for(chunk <- absent, do: {{:chunk, chunk}, :absent}))
    :ets.insert(table, for(chunk <- generated, do: {{:chunk, chunk}, make_ref()}))
    :ets.insert(table, {:generated, 1})
    table
  end

  # As an owner publishes chunks it generated: rows first, then the count.
  defp generate(table, chunks) do
    :ets.insert(table, for(chunk <- chunks, do: {{:chunk, chunk}, make_ref()}))
    :ets.update_counter(table, :generated, 1)
  end

  test "pending chunks stream the nearest generated ones as a full scan would" do
    :rand.seed(:exsss, {7, 8, 9})
    keys = for sx <- -3..3, sz <- -3..3, do: {sx, sz}

    chunks =
      for {sx, sz} <- keys, x <- (sx * 8)..(sx * 8 + 7), z <- (sz * 8)..(sz * 8 + 7), do: {x, z}

    {generated, absent} = Enum.split_with(chunks, fn _ -> :rand.uniform(3) == 1 end)
    tables = Map.new(keys, &{&1, table(generated, absent)})
    # Some sections are still loading.
    loading = MapSet.new(Enum.take_random(keys, 6))
    owner = self()

    source = fn key ->
      table = tables[key]

      unless MapSet.member?(loading, key),
        do: {owner, table, :ets.lookup_element(table, :generated, 2)}
    end

    reference = fn pending, {cx, cz}, limit ->
      pending
      |> Enum.reject(&MapSet.member?(loading, Grid.region_key(&1)))
      |> Enum.filter(
        &match?(
          [{_, ref}] when is_reference(ref),
          :ets.lookup(tables[Grid.region_key(&1)], {:chunk, &1})
        )
      )
      |> Enum.sort_by(fn {x, z} -> {(x - cx) ** 2 + (z - cz) ** 2, x, z} end)
      |> Enum.take(limit)
    end

    Enum.reduce(1..200, {PendingChunks.new(), MapSet.new()}, fn _, {pending, model} ->
      case :rand.uniform(5) do
        1 ->
          added = Enum.take_random(chunks, 40)
          {PendingChunks.put(pending, added), MapSet.union(model, MapSet.new(added))}

        2 ->
          gone = Enum.take_random(chunks, 40)
          {PendingChunks.delete(pending, gone), MapSet.difference(model, MapSet.new(gone))}

        3 ->
          key = Enum.random(keys)
          {x0, z0} = {elem(key, 0) * 8, elem(key, 1) * 8}

          generate(
            tables[key],
            for(_ <- 1..5, do: {x0 + :rand.uniform(8) - 1, z0 + :rand.uniform(8) - 1})
          )

          {pending, model}

        _ ->
          center = {:rand.uniform(41) - 21, :rand.uniform(41) - 21}
          limit = Enum.random([1, 9, 64])
          {sent, pending} = PendingChunks.sendable(pending, center, limit, source)
          expected = reference.(model, center, limit)
          assert Enum.map(sent, &elem(&1, 0)) == expected
          assert Enum.all?(sent, &match?({_, {:owner, ^owner}}, &1))
          sent = Enum.map(sent, &elem(&1, 0))
          {PendingChunks.delete(pending, sent), MapSet.difference(model, MapSet.new(sent))}
      end
      |> tap(fn {pending, model} ->
        assert PendingChunks.size(pending) == MapSet.size(model)

        assert Enum.all?(
                 Enum.take_random(chunks, 30),
                 &(PendingChunks.member?(pending, &1) == MapSet.member?(model, &1))
               )
      end)
    end)
  end
end
