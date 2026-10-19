defmodule Valimc.World.ExperienceRequest do
  @moduledoc "Canonical one-unit XP pickup, bound to original player XP and inventory identity."
  alias Valimc.{PlayerExperience, PlayerPickupIntent}
  @max 18_446_744_073_709_551_615
  def max_bytes, do: 143

  def bind(request, %{progression: %{experience: before}, game_mode: %{current: mode}} = snapshot) do
    with false <- mending_pending?(snapshot.inventory),
         true <- request.before === before,
         {:ok, _} <- PlayerExperience.give(before, request.value),
         {:ok, digest} <- PlayerPickupIntent.inventory_digest(snapshot, mode == :creative),
         true <- Map.get(request, :inventory_digest, digest) == digest do
      {:ok, Map.put(request, :inventory_digest, digest)}
    else
      _ -> {:error, :experience_player_conflict}
    end
  end

  def bind(_, _), do: {:error, :experience_player_conflict}

  # Mending needs a journaled equipment-repair decision. Keep the orb until that
  # path exists rather than converting repair XP into ordinary points.
  defp mending_pending?(inventory) do
    Enum.any?([5, 6, 7, 8, 36 + inventory.selected, 45], fn slot ->
      case Valimc.Inventory.get(inventory, slot) do
        nil ->
          false

        stack ->
          Map.get(stack.components, "minecraft:damage", 0) > 0 and
            Map.get(
              Map.get(stack.components, "minecraft:enchantments", %{}),
              "minecraft:mending",
              0
            ) > 0
      end
    end)
  end

  def encode(
        {rx, rz},
        %{
          kind: :experience,
          source: <<_::128>> = source,
          sequence: sequence,
          permit: <<_::128>> = permit,
          position: {x, y, z},
          orb_uuid: <<_::128>> = uuid,
          value: value,
          consumed: consumed,
          before: before,
          inventory_digest: <<_::256>> = digest,
          collector: collector
        } = request
      )
      when map_size(request) == 11 and is_integer(collector) and collector in 1..2_147_483_647 and
             is_integer(sequence) and sequence in 1..@max and
             is_integer(value) and value in 1..2477 and is_integer(consumed) and
             consumed in 0..2_147_483_647 do
    true = Enum.all?([rx, rz], &(is_integer(&1) and &1 in -2_147_483_648..2_147_483_647))

    true =
      is_integer(x) and abs(x) <= 29_999_984 and is_integer(z) and abs(z) <= 29_999_984 and
        is_integer(y) and abs(y) <= 1_000_000

    true = Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == {rx, rz}
    {:ok, xp} = PlayerExperience.encode(before)

    {:ok,
     <<"VMCXPICK", 1, 5023::32, rx::signed-32, rz::signed-32, source::binary, sequence::64,
       permit::binary, x::signed-32, y::signed-32, z::signed-32, uuid::binary, value::16,
       consumed::32, xp::binary, digest::binary, collector::32>>}
  rescue
    _ -> {:error, :invalid_experience_request}
  end

  def encode(_, _), do: {:error, :invalid_experience_request}

  def decode(
        <<"VMCXPICK", 1, 5023::32, rx::signed-32, rz::signed-32, source::binary-size(16),
          sequence::64, permit::binary-size(16), x::signed-32, y::signed-32, z::signed-32,
          uuid::binary-size(16), value::16, consumed::32, xp::binary-size(12),
          digest::binary-size(32), collector::32>> = bytes,
        {rx, rz} = key
      ) do
    {:ok, before} = PlayerExperience.decode(xp)

    request = %{
      kind: :experience,
      source: source,
      sequence: sequence,
      permit: permit,
      position: {x, y, z},
      orb_uuid: uuid,
      value: value,
      consumed: consumed,
      before: before,
      inventory_digest: digest,
      collector: collector
    }

    {:ok, ^bytes} = encode(key, request)
    {:ok, request}
  rescue
    _ -> {:error, :invalid_experience_request}
  end

  def decode(_, _), do: {:error, :invalid_experience_request}
end
