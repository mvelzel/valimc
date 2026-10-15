defmodule Valimc.Physics.BodySweep do
  @moduledoc "Bounded native ordered swept-body candidates; callers resolve fenced block effects."
  alias Valimc.Physics.Box
  @tiny_square 9.999999439624929e-11
  @epsilon 9.999999747378752e-6
  @clip_epsilon 1.0e-7
  @max_float 1.7976931348623157e308

  @doc "The supplied destination body is already deflated for native inside-block checks."
  def plan(from, to, box, stop_after \\ 512)

  def plan(from, to, box, stop_after) when stop_after in 1..512 do
    if point?(from) and point?(to) and Box.valid?(box) do
      delta = subtract(to, from)
      sizes = for axis <- 0..2, do: elem(box, axis + 3) - elem(box, axis)

      if Enum.all?(Tuple.to_list(delta), &(abs(&1) <= 64)) and
           Enum.all?(sizes, &(&1 > 0 and &1 <= 16)) and
           Enum.all?(0..5, &(abs(elem(box, &1) - elem(delta, rem(&1, 3))) <= 60_000_000)) do
        ctx = %{seen: MapSet.new(), visits: [], count: 0, attempts: 0, stop: stop_after}

        if square(delta) < @tiny_square do
          with {:ok, cells} <- cells(box, {0.0, 0.0, 0.0}, true),
               do: finish(visit(ctx, cells, 0))
        else
          # Java permits infinite reciprocals for subnormal components. The
          # BEAM does not; decline that bounded query instead of raising.
          if Enum.any?(Tuple.to_list(delta), &(&1 != 0 and abs(&1) < 1.0e-308)),
            do: {:error, :body_sweep_limit},
            else: run(ctx, delta, box, List.to_tuple(sizes)) |> finish()
        end
      else
        {:error, :body_sweep_limit}
      end
    else
      {:error, :invalid_body_sweep}
    end
  end

  def plan(_, _, _, _), do: {:error, :invalid_body_sweep}

  defp run(ctx, delta, box, sizes) do
    with {:ok, initial} <- cells(Box.move(box, scale(delta, -1)), delta),
         {:ok, ctx} <- visit(ctx, initial, 0) do
      corner = corner(delta)

      endpoint =
        tuple(fn i ->
          elem(box, i) + 0.5 * elem(sizes, i) + 0.5 * elem(sizes, i) * elem(corner, i)
        end)

      start = subtract(endpoint, delta)
      signs = tuple(fn i -> sign(elem(delta, i)) end)

      intervals =
        tuple(fn i ->
          if elem(signs, i) == 0, do: @max_float, else: elem(signs, i) / elem(delta, i)
        end)

      times =
        tuple(fn i ->
          fraction = elem(start, i) - floor(elem(start, i))
          elem(intervals, i) * if(elem(signs, i) > 0, do: 1.0 - fraction, else: fraction)
        end)

      walk(
        ctx,
        %{
          delta: delta,
          box: box,
          sizes: sizes,
          corner: corner,
          start: start,
          endpoint: endpoint,
          signs: signs,
          intervals: intervals
        },
        tuple(fn i -> floor(elem(start, i)) end),
        times,
        0,
        0
      )
    end
  end

  defp walk(_, _, _, _, _, steps) when steps > 256, do: {:error, :body_sweep_limit}

  defp walk(ctx, data, grid, {tx, ty, tz} = times, step, steps) do
    if tx > 1.0 and ty > 1.0 and tz > 1.0 do
      with {:ok, final} <- cells(data.box, data.delta), do: visit(ctx, final, step + 1)
    else
      axis = if tx < ty, do: if(tx < tz, do: 0, else: 2), else: if(ty < tz, do: 1, else: 2)
      grid = put_elem(grid, axis, elem(grid, axis) + elem(data.signs, axis))
      times = put_elem(times, axis, elem(times, axis) + elem(data.intervals, axis))

      case clip(grid, data.start, data.endpoint) do
        nil ->
          walk(ctx, data, grid, times, step, steps + 1)

        hit ->
          back =
            tuple(fn i ->
              lo = elem(grid, i) * 1.0
              clamped = hit |> elem(i) |> max(lo + @epsilon) |> min(lo + 1.0 - @epsilon)
              floor(clamped - elem(data.sizes, i) * elem(data.corner, i))
            end)

          with {:ok, crossed} <- cells(join(grid, back), data.delta),
               {:ok, ctx} <- visit(ctx, crossed, step + 1),
               do: walk(ctx, data, grid, times, step + 1, steps + 1)
      end
    end
  end

  defp cells(box, delta, stationary \\ false) do
    lo = tuple(fn i -> floor(min(elem(box, i), elem(box, i + 3))) end)
    hi = tuple(fn i -> floor(max(elem(box, i), elem(box, i + 3))) end)
    count = Enum.reduce(0..2, 1, fn i, n -> n * (elem(hi, i) - elem(lo, i) + 1) end)

    if count <= 512 do
      {a, b, c} =
        cond do
          stationary -> {2, 1, 0}
          abs(elem(delta, 0)) < abs(elem(delta, 2)) -> {1, 2, 0}
          true -> {1, 0, 2}
        end

      ranges =
        tuple(fn i ->
          if elem(delta, i) < 0,
            do: elem(hi, i)..elem(lo, i)//-1,
            else: elem(lo, i)..elem(hi, i)//1
        end)

      positions =
        for x <- elem(ranges, a),
            y <- elem(ranges, b),
            z <- elem(ranges, c),
            do: {0, 0, 0} |> put_elem(a, x) |> put_elem(b, y) |> put_elem(c, z)

      {:ok, positions}
    else
      {:error, :body_sweep_limit}
    end
  end

  defp visit(ctx, cells, step) do
    Enum.reduce_while(cells, {:ok, ctx}, fn pos, {:ok, ctx} ->
      ctx = %{ctx | attempts: ctx.attempts + 1}

      cond do
        ctx.attempts > 4096 ->
          {:halt, {:error, :body_sweep_limit}}

        MapSet.member?(ctx.seen, pos) ->
          {:cont, {:ok, ctx}}

        true ->
          ctx = %{
            ctx
            | seen: MapSet.put(ctx.seen, pos),
              visits: [{pos, step} | ctx.visits],
              count: ctx.count + 1
          }

          if ctx.count >= ctx.stop, do: {:halt, {:stopped, ctx}}, else: {:cont, {:ok, ctx}}
      end
    end)
  end

  # Entry faces use the native strict segment/plane tests, including ties and
  # recomputed endpoint deltas at remote coordinates.
  defp clip(grid, start, endpoint) do
    delta = subtract(endpoint, start)

    t =
      Enum.reduce(0..2, nil, fn axis, best ->
        d = elem(delta, axis)

        if abs(d) > @clip_epsilon do
          plane = elem(grid, axis) + if(d < 0, do: 1.0, else: 0.0)
          t = (plane - elem(start, axis)) / d

          valid =
            t > 0 and t < (best || 1.0) and
              Enum.all?(0..2, fn i ->
                p = elem(start, i) + t * elem(delta, i)

                i == axis or
                  (p > elem(grid, i) - @clip_epsilon and p < elem(grid, i) + 1.0 + @clip_epsilon)
              end)

          if valid, do: t, else: best
        else
          best
        end
      end)

    if t, do: tuple(fn i -> elem(start, i) + t * elem(delta, i) end)
  end

  defp corner({x, y, z}) do
    {sx, sy, sz} = {direction(x), direction(y), direction(z)}

    cond do
      abs(x) <= abs(y) and abs(x) <= abs(z) -> {-sx, -sz, sy}
      abs(y) <= abs(z) -> {sz, -sy, -sx}
      true -> {-sy, sx, -sz}
    end
  end

  defp finish({:ok, ctx}), do: {:ok, %{visits: Enum.reverse(ctx.visits), complete: true}}
  defp finish({:stopped, ctx}), do: {:ok, %{visits: Enum.reverse(ctx.visits), complete: false}}
  defp finish(error), do: error
  defp tuple(fun), do: {fun.(0), fun.(1), fun.(2)}
  defp join({x, y, z}, {a, b, c}), do: {x, y, z, a, b, c}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
  defp scale({x, y, z}, factor), do: {x * factor, y * factor, z * factor}
  defp square({x, y, z}), do: x * x + y * y + z * z
  defp sign(x) when x == 0, do: 0
  defp sign(x), do: direction(x)
  defp direction(x), do: if(x < 0, do: -1, else: 1)
  defp point?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 60_000_000))
  defp point?(_), do: false
end
