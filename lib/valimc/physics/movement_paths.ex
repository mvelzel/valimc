defmodule Valimc.Physics.MovementPaths do
  @moduledoc "Transient movement history owned by an entity; bounded independently of packet rates."
  defstruct queue: {[], []}, count: 0

  @gap_squared 9.999999439624929e-11

  @doc "Enclose retained paths for admission before sampling any geometry."
  def enclose(%__MODULE__{queue: queue}, box) do
    queue
    |> :queue.to_list()
    |> Enum.reduce_while({:ok, box}, fn path, {:ok, box} ->
      with {:ok, from} <- Valimc.Physics.PlayerPose.geometry(:standing, path.from),
           {:ok, to} <- Valimc.Physics.PlayerPose.geometry(:standing, path.to) do
        # Inside-fluid contact needs the state above every retained body's head.
        from_box = Valimc.Physics.Box.expand_towards(from.box, {0.0, 1.0, 0.0})
        to_box = Valimc.Physics.Box.expand_towards(to.box, {0.0, 1.0, 0.0})
        {:cont, {:ok, union(union(box, from_box), to_box)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  @doc "Record physical travel after collision; axis order uses the supplied pre-collision displacement."
  def record(%__MODULE__{} = history, from, actual, requested) do
    if records?(actual, requested) do
      append(history, %{from: from, to: add(from, actual), axis: requested})
    else
      history
    end
  end

  @doc "Native move admission: a substantially blocked tiny displacement does not change position."
  def records?(actual, requested) do
    actual_squared = squared(actual)
    actual_squared > 1.0e-7 or squared(requested) - actual_squared < 1.0e-7
  end

  @doc "Include the final position gap, or old-to-current travel when no move was recorded."
  def collect(%__MODULE__{count: 0}, old, current),
    do: [%{from: old, to: current, axis: nil}]

  def collect(%__MODULE__{queue: queue}, _old, current) do
    paths = :queue.to_list(queue)
    {:value, last} = :queue.peek_r(queue)

    if squared(subtract(current, last.to)) > @gap_squared,
      do: paths ++ [%{from: last.to, to: current, axis: nil}],
      else: paths
  end

  defp append(%__MODULE__{queue: queue, count: 100}, path) do
    {{:value, first}, queue} = :queue.out(queue)
    {{:value, second}, queue} = :queue.out(queue)
    merged = %{from: first.from, to: second.to, axis: nil}
    %__MODULE__{queue: :queue.in(path, :queue.in_r(merged, queue)), count: 100}
  end

  defp append(%__MODULE__{queue: queue, count: count}, path),
    do: %__MODULE__{queue: :queue.in(path, queue), count: count + 1}

  defp squared({x, y, z}), do: x * x + y * y + z * z
  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}

  defp union({a, b, c, d, e, f}, {g, h, i, j, k, l}),
    do: Valimc.Physics.Box.new({min(a, g), min(b, h), min(c, i), max(d, j), max(e, k), max(f, l)})
end
