defmodule Valimc.World.ContainerLifecycle do
  @moduledoc "Pure owner-local ordinary chest metadata proposal. Every removed entry must be spilled in the same joint block/item/container commit."
  alias Valimc.{ChestAccess, World}
  alias Valimc.Protocol.Data
  alias Valimc.World.{Chunk, Containers}
  @path Path.expand("../../../priv/protocol/chest_states.json", __DIR__)
  @external_resource @path
  @double JSON.decode!(File.read!(@path))["states"]
          |> Enum.reject(&(&1["part"] == "single"))
          |> MapSet.new(& &1["state"])

  def plan(%Containers{} = containers, key, expected, edits)
      when is_map(expected) and is_map(edits) and map_size(edits) in 1..4096 and
             map_size(expected) == map_size(edits) do
    with true <- Enum.all?(edits, &valid_change?(&1, key, expected)),
         {:ok, _} <- Containers.encode(key, containers),
         {:ok, retained, removed} <- retire(containers, expected, edits),
         {:ok, next} <- create(retained, key, expected, edits),
         {:ok, _} <- Containers.encode(key, next) do
      {:ok, %{containers: next, removed: removed}}
    else
      false -> {:error, :invalid_container_lifecycle}
      error -> error
    end
  end

  def plan(_, _, _, _), do: {:error, :invalid_container_lifecycle}

  defp valid_change?({{x, y, z} = position, state}, key, expected)
       when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(state) do
    original = expected[position]

    abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and Chunk.valid_y?(y) and
      World.region_key(World.chunk_key(x, z)) == key and
      is_integer(original) and original >= 0 and original < Data.block_state_count() and
      state >= 0 and state < Data.block_state_count() and
      not MapSet.member?(@double, original) and not MapSet.member?(@double, state)
  end

  defp valid_change?(_, _, _), do: false

  defp retire(containers, expected, edits) do
    edits
    |> Enum.sort()
    |> Enum.reduce_while({:ok, containers, []}, fn {position, replacement},
                                                   {:ok, current, removed} ->
      case {ChestAccess.single?(expected[position]), current.entries[position]} do
        {true, %{rows: 3, slots: slots} = entry} when tuple_size(slots) == 27 ->
          if ChestAccess.single?(replacement) do
            {:cont, {:ok, current, removed}}
          else
            case Containers.remove(current, position, entry.revision) do
              {:ok, next, ^entry} ->
                {:cont, {:ok, next, [%{position: position, entry: entry} | removed]}}

              error ->
                {:halt, error}
            end
          end

        {true, _} ->
          {:halt, {:error, :missing_or_invalid_chest}}

        {false, nil} ->
          {:cont, {:ok, current, removed}}

        {false, _} ->
          {:halt, {:error, :unexpected_container}}
      end
    end)
    |> case do
      {:ok, current, removed} -> {:ok, current, Enum.reverse(removed)}
      error -> error
    end
  end

  # Retire before creating: a full region can atomically move an empty chest to a new position.
  defp create(containers, key, expected, edits) do
    edits
    |> Enum.sort()
    |> Enum.reduce_while({:ok, containers}, fn {position, replacement}, {:ok, current} ->
      if ChestAccess.single?(replacement) and not ChestAccess.single?(expected[position]) do
        case Containers.create(current, key, position, 3) do
          {:ok, next, _} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, current}}
      end
    end)
  end
end
