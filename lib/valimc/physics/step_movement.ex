defmodule Valimc.Physics.StepMovement do
  @moduledoc "Pure bounded step-up preparation/completion; collider observations need separate owner fencing."
  alias Valimc.Physics.{Box, Collision, Shape}
  defstruct [:box, :start_box, :query, :requested, :base, :max_step]
  @query_epsilon -9.999999747378752e-6
  @max_heights 128

  def prepare(box, initial_shapes, requested, max_step, grounded) do
    with true <-
           Box.valid?(box) and vector?(requested) and is_boolean(grounded) and step?(max_step),
         {:ok, shapes} <- shapes(initial_shapes) do
      {dx, dy, dz} = float_vector(requested)
      max_step = f32(max_step)

      base =
        if dx * dx + dy * dy + dz * dz == 0.0,
          do: {dx, dy, dz},
          else: Collision.move(box, shapes, {dx, dy, dz})

      {bx, by, bz} = base
      down = dy < 0 and dy != by

      if max_step > 0 and (down or grounded) and (dx != bx or dz != bz) do
        start_box = if down, do: Box.move(box, {0, by, 0}), else: box
        query = Box.expand_towards(start_box, {dx, max_step, dz})
        query = if down, do: query, else: Box.expand_towards(query, {0, @query_epsilon, 0})

        {:step,
         %__MODULE__{
           box: box,
           start_box: start_box,
           query: query,
           requested: {dx, dy, dz},
           base: base,
           max_step: max_step
         }}
      else
        {:resolved, base}
      end
    else
      false -> {:error, :invalid_step_query}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_step_query}
  end

  def finish(%__MODULE__{} = plan, supplied) do
    with true <- valid_plan?(plan),
         {:ok, shapes} <- shapes(supplied),
         {:ok, heights} <- heights(plan.start_box, shapes, plan.max_step, f32(elem(plan.base, 1))) do
      {dx, _, dz} = plan.requested

      result =
        Enum.reduce_while(heights, plan.base, fn height, _ ->
          {x, y, z} = candidate = Collision.move(plan.start_box, shapes, {dx, height, dz})

          if horizontal(candidate) > horizontal(plan.base) do
            correction = elem(plan.box, 1) - elem(plan.start_box, 1)
            {:halt, {x - 0.0, y - correction, z - 0.0}}
          else
            {:cont, plan.base}
          end
        end)

      {:ok, result}
    else
      false -> {:error, :invalid_step_plan}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_step_query}
  end

  def finish(_, _), do: {:error, :invalid_step_plan}

  @doc false
  def candidate_heights(box, supplied, max_step, previous) do
    with true <-
           Box.valid?(box) and step?(max_step) and is_number(previous) and abs(previous) <= 64,
         {:ok, shapes} <- shapes(supplied) do
      heights(box, shapes, f32(max_step), f32(previous))
    else
      false -> {:error, :invalid_step_query}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_step_query}
  end

  defp heights(box, shapes, max_step, previous) do
    values =
      Enum.reduce_while(shapes, %{}, fn shape, acc ->
        added =
          Enum.reduce_while(Tuple.to_list(elem(shape.axes, 1)), acc, fn coordinate, values ->
            value = f32(coordinate - elem(box, 1))

            cond do
              value < 0 or value == previous ->
                {:cont, values}

              value > max_step ->
                {:halt, values}

              true ->
                <<bits::32>> = <<value::float-32>>
                next = Map.put(values, bits, value)
                if map_size(next) > @max_heights, do: {:halt, :limit}, else: {:cont, next}
            end
          end)

        if added == :limit, do: {:halt, :limit}, else: {:cont, added}
      end)

    if values == :limit do
      {:error, :step_height_limit}
    else
      {:ok,
       values
       |> Enum.sort(fn {ab, a}, {bb, b} -> if a == b, do: ab > bb, else: a < b end)
       |> Enum.map(&elem(&1, 1))}
    end
  end

  defp shapes(list), do: shapes(list, [], 0)
  defp shapes([], acc, _), do: validate_shapes(Enum.reverse(acc))
  defp shapes([_ | _], _, 128), do: {:error, :step_shape_limit}
  defp shapes([shape | rest], acc, count), do: shapes(rest, [shape | acc], count + 1)
  defp shapes(_, _, _), do: {:error, :invalid_step_query}

  defp validate_shapes(list) do
    Enum.each(list, fn %Shape{} = shape ->
      unless bounded_shape?(shape), do: raise(ArgumentError, "oversized step shape")

      Shape.from_world_facts!(%{
        "axes" => shape.axes |> Tuple.to_list() |> Enum.map(&Tuple.to_list/1),
        "sizes" => Tuple.to_list(shape.sizes),
        "bits" => Base.encode16(shape.bits, case: :lower),
        "boxes" => Enum.map(shape.boxes, &Tuple.to_list/1),
        "full_block" => shape.full_block
      })
    end)

    {:ok, list}
  rescue
    _ -> {:error, :invalid_step_query}
  end

  defp bounded_shape?(shape),
    do:
      is_tuple(shape.axes) and tuple_size(shape.axes) == 3 and
        Enum.all?(Tuple.to_list(shape.axes), &(is_tuple(&1) and tuple_size(&1) <= 33)) and
        is_tuple(shape.sizes) and tuple_size(shape.sizes) == 3 and
        is_binary(shape.bits) and byte_size(shape.bits) <= 4096 and boxes?(shape.boxes, 0)

  defp boxes?([], _), do: true

  defp boxes?([box | rest], count) when count < 64 and is_tuple(box) and tuple_size(box) == 6,
    do: boxes?(rest, count + 1)

  defp boxes?(_, _), do: false

  defp valid_plan?(p),
    do:
      Box.valid?(p.box) and Box.valid?(p.start_box) and Box.valid?(p.query) and
        vector?(p.requested) and vector?(p.base) and step?(p.max_step) and p.max_step > 0 and
        elem(p.box, 1) - elem(p.start_box, 1) >= 0 and
        elem(p.box, 1) - elem(p.start_box, 1) <= 64

  defp vector?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))
  defp vector?(_), do: false
  defp step?(v), do: is_number(v) and v >= 0 and v <= 64
  defp float_vector({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}
  defp horizontal({x, _, z}), do: x * x + z * z

  defp f32(v) do
    <<value::float-32>> = <<v::float-32>>
    value
  end
end
