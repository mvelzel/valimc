defmodule Valimc.World.ContainerLifecycle do
  @moduledoc "Pure owner-local chest, cooking-block, machine (hopper, dropper, dispenser), storage (barrel, shulker box) and brewing stand metadata proposal. Every removed entry (with the block it belonged to) must be spilled, or a shulker box dropped with it, in the same joint block/item/container commit."
  alias Valimc.Data.Grid
  alias Valimc.Protocol.Data
  alias Valimc.World.{Chunk, Containers}

  @storage Containers.storage()

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
      Grid.region_key(Grid.chunk_key(x, z)) == key and
      is_integer(original) and original >= 0 and original < Data.block_state_count() and
      state >= 0 and state < Data.block_state_count()
  end

  defp valid_change?(_, _, _), do: false

  defp retire(containers, expected, edits) do
    edits
    |> Enum.sort()
    |> Enum.reduce_while({:ok, containers, []}, fn {position, replacement},
                                                   {:ok, current, removed} ->
      case {kind(expected[position]), current.entries[position]} do
        {:chest, %{rows: 3, slots: slots} = entry} when tuple_size(slots) == 27 ->
          if kind(replacement) == :chest,
            do: {:cont, {:ok, current, removed}},
            else: retire_entry(current, position, entry, expected[position], removed)

        {:chest, _} ->
          {:halt, {:error, :missing_or_invalid_chest}}

        {original, %{kind: original, cooking: _} = entry}
        when original in [:furnace, :smoker, :blast_furnace] ->
          # An occupied one spills its slots and pays out its stored
          # recipes' experience (VMC-032c5, `ContainerSpills.add/4`).
          if kind(replacement) == original,
            do: {:cont, {:ok, current, removed}},
            else: retire_entry(current, position, entry, expected[position], removed)

        {original, _} when original in [:furnace, :smoker, :blast_furnace] ->
          {:halt, {:error, :missing_or_invalid_cooking_entry}}

        # A brewing stand spills its five slots (`Containers.dropContents`).
        {:brewing_stand, %{kind: :brewing_stand, brewing: _} = entry} ->
          if kind(replacement) == :brewing_stand,
            do: {:cont, {:ok, current, removed}},
            else: retire_entry(current, position, entry, expected[position], removed)

        {:brewing_stand, nil} ->
          {:cont, {:ok, current, removed}}

        {:brewing_stand, _} ->
          {:halt, {:error, :missing_or_invalid_brewing_stand}}

        {original, %{kind: original, slots: _} = entry}
        when original in [:hopper, :dropper, :dispenser] or is_map_key(@storage, original) ->
          if kind(replacement) == original,
            do: {:cont, {:ok, current, removed}},
            else: retire_entry(current, position, entry, expected[position], removed)

        # A machine or barrel without an entry (a generated one with loot,
        # preserved) retires nothing.
        {original, nil}
        when original in [:hopper, :dropper, :dispenser] or is_map_key(@storage, original) ->
          {:cont, {:ok, current, removed}}

        {original, _} when original in [:hopper, :dropper, :dispenser] ->
          {:halt, {:error, :missing_or_invalid_machine}}

        {original, _} when is_map_key(@storage, original) ->
          {:halt, {:error, :missing_or_invalid_storage}}

        {nil, nil} ->
          {:cont, {:ok, current, removed}}

        {nil, _} ->
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
      next_kind = kind(replacement)

      if next_kind != nil and next_kind != kind(expected[position]) do
        case Containers.create_owned(current, key, position, next_kind) do
          {:ok, next, _} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, current}}
      end
    end)
  end

  @doc """
  After a commit that did not plan its containers (box edits, raw sets), the
  entries whose cell no longer holds that kind of container go, contents and
  all, as vanilla's commands clear a replaced block entity
  (`Clearable.tryClear`).
  """
  def retire_replaced(%Containers{} = containers, changes) do
    Enum.reduce(changes, containers, fn {position, state}, current ->
      case current.entries[position] do
        %{revision: revision} = entry ->
          if entry_kind(entry) == kind(state),
            do: current,
            else: elem(Containers.remove(current, position, revision), 1)

        nil ->
          current
      end
    end)
  end

  @doc """
  The empty entry a chest half, cooking block, machine or barrel at `position` lacks, as
  vanilla's block entity exists with the block however it was set
  (`EntityBlock.newBlockEntity`): `{:ok, containers}`, or `:none` when the
  state holds no container or its entry exists.
  """
  def ensure(%Containers{} = containers, key, position, state) do
    # Every half of a joined chest owns its own entry.
    result =
      case kind(state) do
        _ when is_map_key(containers.entries, position) -> :none
        nil -> :none
        kind -> Containers.create_owned(containers, key, position, kind)
      end

    case result do
      {:ok, next, _entry} -> {:ok, next}
      _ -> :none
    end
  end

  defp entry_kind(%{brewing: _}), do: :brewing_stand
  defp entry_kind(%{cooking: _, kind: kind}), do: kind
  defp entry_kind(%{slots: _, kind: kind}), do: kind
  defp entry_kind(_chest), do: :chest

  defp kind(state), do: Valimc.Blocks.block_entity(state)

  defp retire_entry(current, position, entry, block, removed) do
    case Containers.remove(current, position, entry.revision) do
      {:ok, next, ^entry} ->
        {:cont, {:ok, next, [%{position: position, entry: entry, block: block} | removed]}}

      error ->
        {:halt, error}
    end
  end
end
