defmodule Valimc.World.PickupRequest do
  @moduledoc "Canonical bounded world-withdrawal request; a durable player intent precedes delivery."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  @max_sequence 18_446_744_073_709_551_615
  @stack_bytes 65_536
  @header_bytes 92
  @max_bytes @header_bytes + 2 * @stack_bytes
  def max_bytes, do: @max_bytes

  def encode(
        {rx, rz},
        %{
          source: <<_::128>> = source,
          sequence: sequence,
          permit: <<_::128>> = permit,
          item_uuid: <<_::128>> = item_uuid,
          generation: generation,
          before: %ItemStack{} = before,
          remainder: remainder
        } = request
      )
      when is_integer(rx) and rx in -2_147_483_648..2_147_483_647 and
             is_integer(rz) and rz in -2_147_483_648..2_147_483_647 and
             is_integer(sequence) and sequence in 1..@max_sequence and
             is_integer(generation) and generation in 0..@max_sequence and map_size(request) == 7 do
    with true <- before.item_id != ItemTypes.id("air"),
         true <- remaining?(before, remainder),
         before_bytes = before |> ItemStack.encode() |> IO.iodata_to_binary(),
         remainder_bytes = remainder |> ItemStack.encode() |> IO.iodata_to_binary(),
         true <-
           byte_size(before_bytes) <= @stack_bytes and byte_size(remainder_bytes) <= @stack_bytes do
      {:ok,
       <<"VMCPICK", 1, 5023::32, rx::signed-32, rz::signed-32, source::binary-size(16),
         sequence::64, permit::binary-size(16), item_uuid::binary-size(16), generation::64,
         byte_size(before_bytes)::32, byte_size(remainder_bytes)::32, before_bytes::binary,
         remainder_bytes::binary>>}
    else
      _ -> {:error, :invalid_pickup_request}
    end
  rescue
    _ -> {:error, :invalid_pickup_request}
  catch
    _, _ -> {:error, :invalid_pickup_request}
  end

  def encode(_, _), do: {:error, :invalid_pickup_request}

  def decode(bytes, {rx, rz} = key)
      when is_binary(bytes) and
             byte_size(bytes) in @header_bytes..@max_bytes do
    with <<"VMCPICK", 1, 5023::32, ^rx::signed-32, ^rz::signed-32, source::binary-size(16),
           sequence::64, permit::binary-size(16), item_uuid::binary-size(16), generation::64,
           before_size::32, remainder_size::32, body::binary>> <- bytes,
         true <- before_size in 1..@stack_bytes and remainder_size in 1..@stack_bytes,
         <<before_bytes::binary-size(^before_size),
           remainder_bytes::binary-size(^remainder_size)>> <- body,
         {:ok, before} <- ItemStack.decode(before_bytes),
         {:ok, remainder} <- ItemStack.decode(remainder_bytes),
         request = %{
           source: source,
           sequence: sequence,
           permit: permit,
           item_uuid: item_uuid,
           generation: generation,
           before: before,
           remainder: remainder
         },
         {:ok, ^bytes} <- encode(key, request) do
      {:ok, request}
    else
      _ -> {:error, :invalid_pickup_request}
    end
  rescue
    _ -> {:error, :invalid_pickup_request}
  end

  def decode(_, _), do: {:error, :invalid_pickup_request}

  def digest(key, request) do
    with {:ok, bytes} <- encode(key, request), do: {:ok, :crypto.hash(:sha256, bytes)}
  end

  defp remaining?(_, nil), do: true

  defp remaining?(%ItemStack{} = before, %ItemStack{} = remainder),
    do: remainder.count < before.count and %{before | count: remainder.count} == remainder

  defp remaining?(_, _), do: false
end
