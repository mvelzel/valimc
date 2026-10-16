defmodule Valimc.PlayerPickupIntent do
  @moduledoc "Typed pickup intent keeps the original inventory until receipt-backed withdrawal."
  alias Valimc.{GameMode, Inventory}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.PickupRequest
  def max_bytes, do: 41 + PickupRequest.max_bytes()

  def bind(%{kind: :pickup} = intent, %{game_mode: %GameMode{current: mode}} = snapshot)
      when map_size(intent) == 3 and mode in [:survival, :adventure, :creative] do
    infinite = mode == :creative

    with {:ok, digest} <- inventory_digest(snapshot, infinite),
         do: {:ok, Map.merge(intent, %{inventory_digest: digest, infinite_materials: infinite})}
  end

  def bind(_, _), do: {:error, :invalid_pickup_intent}

  def encode(
        uuid,
        sequence,
        %{
          kind: :pickup,
          key: key,
          inventory_digest: <<_::256>> = digest,
          infinite_materials: infinite,
          request: %{source: uuid, sequence: sequence} = request
        } =
          intent
      )
      when map_size(intent) == 5 and is_boolean(infinite) do
    with {:ok, bytes} <- PickupRequest.encode(key, request),
         do: {:ok, <<"VMCIOUT", 1, if(infinite, do: 1, else: 0), digest::binary, bytes::binary>>}
  end

  def encode(_, _, _), do: {:error, :invalid_pickup_intent}

  def decode(
        uuid,
        sequence,
        <<"VMCIOUT", 1, infinite, digest::binary-size(32), "VMCPICK", 1, 5023::32, rx::signed-32,
          rz::signed-32, rest::binary>>
      )
      when infinite in 0..1 do
    bytes = <<"VMCPICK", 1, 5023::32, rx::signed-32, rz::signed-32, rest::binary>>

    with {:ok, %{source: ^uuid, sequence: ^sequence} = request} <-
           PickupRequest.decode(bytes, {rx, rz}) do
      {:ok,
       %{
         kind: :pickup,
         key: {rx, rz},
         request: request,
         inventory_digest: digest,
         infinite_materials: infinite == 1
       }}
    else
      _ -> {:error, :invalid_pickup_intent}
    end
  end

  def decode(_, _, _), do: {:error, :invalid_pickup_intent}

  def request(uuid, sequence, %{kind: :pickup, key: key, request: request} = intent) do
    with {:ok, _} <- encode(uuid, sequence, intent),
         {:ok, digest} <- PickupRequest.digest(key, request),
         do: {:ok, key, request, digest}
  end

  def request(_, _, _), do: {:error, :invalid_pickup_intent}

  def inventory_result(
        %{
          kind: :pickup,
          request: request,
          inventory_digest: digest,
          infinite_materials: infinite
        },
        %{
          inventory: %Inventory{} = inventory
        } = snapshot
      )
      when is_boolean(infinite) do
    # Permission belongs to the accepted intent. A later mode change cannot
    # reinterpret a prepared survival remainder as creative overflow disposal.
    inventory = %{inventory | infinite_materials: infinite}

    with {:ok, ^digest} <- inventory_digest(snapshot, infinite),
         {:ok, next, remainder, callback} <- Inventory.pickup_stack(inventory, request.before),
         true <- remainder == request.remainder do
      {:ok, next, callback}
    else
      _ -> {:error, :pickup_inventory_conflict}
    end
  rescue
    _ -> {:error, :pickup_inventory_conflict}
  end

  def inventory_result(_, _), do: {:error, :pickup_inventory_conflict}

  def matches_snapshot?(intent, snapshot),
    do: match?({:ok, _, _}, inventory_result(intent, snapshot))

  defp inventory_digest(
         %{
           inventory: %Inventory{selected: selected} = inventory
         },
         infinite
       )
       when selected in 0..8 and is_boolean(infinite) do
    bytes = [
      for(slot <- 1..45, do: ItemStack.encode(Inventory.get(inventory, slot))),
      ItemStack.encode(inventory.carried),
      Enum.map(Inventory.table_contents(inventory), &ItemStack.encode/1)
    ]

    if IO.iodata_length(bytes) <= 524_288,
      do:
        {:ok,
         :crypto.hash(:sha256, [
           "VMCPICK-INVENTORY",
           <<if(infinite, do: 1, else: 0), selected,
             if(inventory.table_inputs == nil, do: 0, else: 1)>>,
           bytes
         ])},
      else: {:error, :pickup_inventory_conflict}
  rescue
    _ -> {:error, :pickup_inventory_conflict}
  catch
    _, _ -> {:error, :pickup_inventory_conflict}
  end

  defp inventory_digest(_, _), do: {:error, :pickup_inventory_conflict}
end
