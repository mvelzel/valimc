defmodule Valimc.Physics.BodyPaths do
  @moduledoc "Bounded ordered body candidates for retained movement paths; callers resolve fenced effects."
  alias Valimc.Physics.{Box, Kernel, PlayerPose}
  @epsilon 9.999999747378752e-6

  def reduce(paths, pose, initial, visitor)
      when is_list(paths) and length(paths) <= 101 and is_function(visitor, 5) do
    Enum.reduce_while(paths, {:ok, %{value: initial, attempts: 0}}, fn path, {:ok, acc} ->
      case movement(path, pose, acc, visitor) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc.value}
      error -> error
    end
  end

  def reduce(_, _, _, _), do: {:error, :invalid_contact_paths}

  defp movement(path, pose, acc, visitor) do
    with {:ok, segments, destination} <- segments(path),
         {:ok, {acc, remaining}} <-
           Enum.reduce_while(segments, {:ok, {acc, 16}}, fn {from, to}, {:ok, {acc, budget}} ->
             case line(from, to, pose, acc, budget, visitor) do
               {:ok, acc, used} -> {:cont, {:ok, {acc, budget - used}}}
               error -> {:halt, error}
             end
           end) do
      if remaining <= 0 do
        with {:ok, acc, _} <- line(destination, destination, pose, acc, 1, visitor),
             do: {:ok, acc}
      else
        {:ok, acc}
      end
    end
  end

  defp segments(%{from: from, to: to} = path) do
    axis = Map.get(path, :axis)

    if point?(from) and point?(to) and (axis == nil or vector?(axis)) and
         vector?(subtract(to, from)) do
      delta = subtract(to, from)

      {dx, dy, dz} = delta

      if axis != nil and dx * dx + dy * dy + dz * dz > 0 do
        order = if abs(elem(axis, 0)) < abs(elem(axis, 2)), do: [1, 2, 0], else: [1, 0, 2]

        {_, segments} =
          Enum.reduce(order, {from, []}, fn i, {current, segments} ->
            d = elem(delta, i)

            if d == 0 do
              {current, segments}
            else
              next = put_elem(current, i, elem(current, i) + d)
              {next, [{current, next} | segments]}
            end
          end)

        {:ok, Enum.reverse(segments), to}
      else
        {:ok, [{from, to}], to}
      end
    else
      {:error, :body_contact_limit}
    end
  end

  defp segments(_), do: {:error, :invalid_contact_path}

  defp line(from, to, pose, acc, budget, visitor) do
    with {:ok, before} <- PlayerPose.geometry(pose, from),
         {:ok, after_move} <- PlayerPose.geometry(pose, to),
         {:ok, sweep} <- Kernel.sweep(from, to, deflate(after_move.box)) do
      result =
        Enum.reduce_while(sweep.visits, {:ok, acc, 0}, fn {pos, step}, {:ok, acc, last_step} ->
          cond do
            step >= budget ->
              {:halt, {:budget, acc, last_step}}

            acc.attempts >= 4096 ->
              {:halt, {:error, :body_contact_limit}}

            true ->
              acc = %{acc | attempts: acc.attempts + 1}

              case visitor.(acc.value, pos, step, before.box, subtract(to, from)) do
                {:ok, value} -> {:cont, {:ok, %{acc | value: value}, step}}
                error -> {:halt, error}
              end
          end
        end)

      case result do
        {:budget, acc, step} -> {:ok, acc, step + 1}
        {:ok, acc, step} when sweep.complete -> {:ok, acc, step + 1}
        {:ok, _, _} -> {:error, :body_contact_limit}
        error -> error
      end
    end
  end

  defp deflate({a, b, c, d, e, f}),
    do:
      Box.new(
        {a + @epsilon, b + @epsilon, c + @epsilon, d - @epsilon, e - @epsilon, f - @epsilon}
      )

  defp point?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 60_000_000))
  defp point?(_), do: false
  defp vector?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))
  defp vector?(_), do: false
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
end
