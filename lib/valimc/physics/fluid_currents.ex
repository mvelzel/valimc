defmodule Valimc.Physics.FluidCurrents do
  @moduledoc "Native player current averaging and minimum push, calculated outside gameplay owners."
  alias Valimc.Physics.{FluidContact, FluidFlow}
  @empty %{height: 0.0, sum: {0.0, 0.0, 0.0}, count: 0}

  def sample(frame, box, velocity, pushed \\ true, fast_lava \\ false) do
    if valid_velocity?(velocity) and is_boolean(pushed) and is_boolean(fast_lava) do
      with {:ok, contacts} <- FluidContact.contacts(frame, box),
           {:ok, accumulators} <- accumulate(contacts, frame, pushed),
           next =
             velocity
             |> apply_current(accumulators.water, 0.014)
             |> apply_current(
               accumulators.lava,
               if(fast_lava, do: 0.007, else: 0.0023333333333333335)
             ),
           true <- valid_velocity?(next) do
        {:ok,
         %{
           depths: %{water: accumulators.water.height, lava: accumulators.lava.height},
           velocity: next
         }}
      else
        false -> {:error, :fluid_velocity_limit}
        error -> error
      end
    else
      {:error, :invalid_fluid_current}
    end
  end

  defp accumulate(contacts, frame, pushed) do
    Enum.reduce_while(contacts, {:ok, %{water: @empty, lava: @empty}}, fn c, {:ok, all} ->
      a = all[c.fluid.kind]
      height = max(a.height, c.depth)

      with {:ok, flow} <-
             if(pushed, do: FluidFlow.sample(frame, c.position), else: {:ok, {0.0, 0.0, 0.0}}) do
        flow = if height < 0.4, do: scale(flow, height), else: flow

        next = %{
          height: height,
          sum: add(a.sum, flow),
          count: a.count + if(pushed, do: 1, else: 0)
        }

        {:cont, {:ok, Map.put(all, c.fluid.kind, next)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp apply_current(velocity, %{count: 0}, _), do: velocity

  defp apply_current({x, _, z} = velocity, %{sum: {sx, sy, sz} = sum, count: count}, factor) do
    if sx * sx + sy * sy + sz * sz < 9.999999747378752e-6 do
      velocity
    else
      push = sum |> scale(1.0 / count) |> scale(factor)
      {a, b, c} = push

      push =
        if abs(x) < 0.003 and abs(z) < 0.003 and
             :math.sqrt(a * a + b * b + c * c) < 0.0045000000000000005,
           do: push |> FluidFlow.normalize() |> scale(0.0045000000000000005),
           else: push

      add(velocity, push)
    end
  end

  defp valid_velocity?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))
  defp valid_velocity?(_), do: false
  defp scale({x, y, z}, factor), do: {x * factor, y * factor, z * factor}
  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}
end
