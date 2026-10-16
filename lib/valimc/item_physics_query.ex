defmodule Valimc.ItemPhysicsQuery do
  @moduledoc "One bounded fenced geometry job per item cohort, with owner-supplied state and ordering."
  alias Valimc.Physics.{BlockCollisions, CollisionQuery, ItemTravel}

  def start(inputs) when is_list(inputs) do
    inputs = Enum.take(inputs, 33)

    with true <- length(inputs) in 1..32 and valid_inputs?(inputs),
         {:ok, boxes} <- boxes(inputs) do
      CollisionQuery.start_batch_frame(boxes, fn observations ->
        with {:ok, frame} <- BlockCollisions.prepare(observations), do: resolve(inputs, frame)
      end)
    else
      false -> {:error, :invalid_item_physics_batch}
      error -> error
    end
  end

  def start(_), do: {:error, :invalid_item_physics_batch}

  defp boxes(inputs) do
    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, boxes} ->
      case ItemTravel.query_box(input) do
        {:ok, box} -> {:cont, {:ok, [box | boxes]}}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_inputs?(inputs) do
    Enum.all?(inputs, fn
      %{id: id, revision: revision} = input
      when is_integer(id) and id in 1..2_147_483_647 and is_integer(revision) and revision > 0 ->
        is_boolean(Map.get(input, :refresh, true))

      _ ->
        false
    end) and length(Enum.uniq_by(inputs, & &1.id)) == length(inputs)
  end

  defp resolve(inputs, frame) do
    {steps, refused} =
      Enum.reduce(inputs, {[], []}, fn input, {steps, refused} ->
        case ItemTravel.sample(input, frame, Map.get(input, :refresh, true)) do
          {:ok, step} -> {[step | steps], refused}
          {:error, reason} -> {steps, [{input.id, reason} | refused]}
        end
      end)

    {:ok, %{steps: Enum.reverse(steps), refused: Enum.reverse(refused), fences: frame.fences}}
  end
end
