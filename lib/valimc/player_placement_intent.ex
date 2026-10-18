defmodule Valimc.PlayerPlacementIntent do
  @moduledoc "Typed survival placement outbox; exact one-item consumption precedes delivery."
  alias Valimc.Inventory
  alias Valimc.Physics.Placement
  alias Valimc.Protocol.{ItemStack, UseItemOn}
  alias Valimc.World.PlacementRequest
  @stack_bytes 65_536
  @max_bytes 19 + 2 * @stack_bytes + 37 + 104
  def max_bytes, do: @max_bytes

  def encode(
        uuid,
        sequence,
        %{
          kind: :placement,
          slot: slot,
          before: %ItemStack{} = before,
          after: after_stack,
          request: hit,
          expected: expected,
          edits: edits
        } = intent
      )
      when slot in 36..45 do
    with true <- Placement.supported_stack?(before),
         true <- (slot == 45 and hit.hand == :off) or (slot in 36..44 and hit.hand == :main),
         true <- Valimc.PlayerInteraction.valid_hit?(hit.position, hit.cursor),
         true <- after_stack == consume(before),
         {:ok, candidate} <-
           Placement.saved_candidate(
             before.item_id,
             expected[hit.position],
             Map.get(expected, Placement.adjacent(hit), 0),
             hit,
             edits
           ),
         true <- edits == %{candidate.position => candidate.state},
         {:ok, key, transfer, _digest} <- request(uuid, sequence, intent),
         {:ok, transfer_bytes} <- PlacementRequest.encode(key, transfer),
         {:ok, hit_bytes} <- UseItemOn.encode(hit),
         {:ok, before_bytes} <- stack_bytes(before),
         {:ok, after_bytes} <- stack_bytes(after_stack) do
      {:ok,
       <<"VMCPOUT", 1, slot, byte_size(before_bytes)::32, byte_size(after_bytes)::32,
         byte_size(hit_bytes), byte_size(transfer_bytes), before_bytes::binary,
         after_bytes::binary, hit_bytes::binary, transfer_bytes::binary>>}
    else
      _ -> {:error, :invalid_placement_intent}
    end
  rescue
    _ -> {:error, :invalid_placement_intent}
  end

  def encode(_, _, _), do: {:error, :invalid_placement_intent}

  def decode(uuid, sequence, bytes)
      when is_binary(bytes) and byte_size(bytes) in 19..@max_bytes do
    <<"VMCPOUT", 1, slot, before_size::32, after_size::32, hit_size, transfer_size, body::binary>> =
      bytes

    with true <-
           before_size in 1..@stack_bytes and after_size in 1..@stack_bytes and hit_size in 25..37 and
             transfer_size <= PlacementRequest.max_bytes(),
         <<before_bytes::binary-size(^before_size), after_bytes::binary-size(^after_size),
           hit_bytes::binary-size(^hit_size), transfer_bytes::binary-size(^transfer_size)>> <-
           body,
         {:ok, before, <<>>} <- ItemStack.take(before_bytes),
         {:ok, after_stack, <<>>} <- ItemStack.take(after_bytes),
         {:ok, hit} <- UseItemOn.decode(hit_bytes),
         {:ok, {rx, rz}} <- key(transfer_bytes),
         {:ok, %{source: ^uuid, sequence: ^sequence} = transfer} <-
           PlacementRequest.decode(transfer_bytes, {rx, rz}) do
      intent = %{
        kind: :placement,
        key: {rx, rz},
        permit: transfer.permit,
        slot: slot,
        before: before,
        after: after_stack,
        request: hit,
        expected: transfer.expected,
        edits: transfer.edits
      }

      with {:ok, ^bytes} <- encode(uuid, sequence, intent),
           do: {:ok, intent},
           else: (_ -> {:error, :invalid_placement_intent})
    else
      _ -> {:error, :invalid_placement_intent}
    end
  rescue
    _ -> {:error, :invalid_placement_intent}
  end

  def decode(_, _, _), do: {:error, :invalid_placement_intent}

  def request(uuid, sequence, %{kind: :placement, key: key} = intent) do
    transfer =
      Map.take(intent, [:permit, :expected, :edits])
      |> Map.merge(%{source: uuid, sequence: sequence})

    with {:ok, digest} <- PlacementRequest.digest(key, transfer), do: {:ok, key, transfer, digest}
  end

  def request(_, _, _), do: {:error, :invalid_placement_intent}

  def matches_inventory?(
        %{kind: :placement, slot: slot, after: after_stack},
        %Inventory{} = inventory
      ),
      do:
        (slot == 45 or slot == 36 + inventory.selected) and
          Inventory.get(inventory, slot) == after_stack

  def matches_inventory?(_, _), do: false

  defp consume(%ItemStack{count: 1}), do: nil
  defp consume(%ItemStack{count: count} = stack) when count > 1, do: %{stack | count: count - 1}

  defp stack_bytes(stack) do
    bytes = stack |> ItemStack.encode() |> IO.iodata_to_binary()

    if byte_size(bytes) <= @stack_bytes,
      do: {:ok, bytes},
      else: {:error, :invalid_placement_intent}
  catch
    {:item_error, _} -> {:error, :invalid_placement_intent}
  end

  defp key(<<"VMCPLACE", 1, 5023::32, rx::signed-32, rz::signed-32, _::binary>>),
    do: {:ok, {rx, rz}}

  defp key(_), do: {:error, :invalid_placement_intent}
end
