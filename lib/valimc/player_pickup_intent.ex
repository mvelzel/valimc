defmodule Valimc.PlayerPickupIntent do
  @moduledoc "Typed pickup intent keeps the original inventory until receipt-backed withdrawal."
  alias Valimc.{GameMode, Inventory}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.PickupRequest
  def max_bytes, do: 40 + PickupRequest.max_bytes()

  def bind(%{kind: :pickup} = intent, snapshot) when map_size(intent) == 3 do
    with {:ok, digest} <- inventory_digest(snapshot),
         do: {:ok, Map.put(intent, :inventory_digest, digest)}
  end

  def bind(_, _), do: {:error, :invalid_pickup_intent}

  def encode(
        uuid,
        sequence,
        %{
          kind: :pickup,
          key: key,
          inventory_digest: <<_::256>> = digest,
          request: %{source: uuid, sequence: sequence} = request
        } =
          intent
      )
      when map_size(intent) == 4 do
    with {:ok, bytes} <- PickupRequest.encode(key, request),
         do: {:ok, <<"VMCIOUT", 1, digest::binary, bytes::binary>>}
  end

  def encode(_, _, _), do: {:error, :invalid_pickup_intent}

  def decode(
        uuid,
        sequence,
        <<"VMCIOUT", 1, digest::binary-size(32), "VMCPICK", 1, 5023::32, rx::signed-32,
          rz::signed-32, rest::binary>>
      ) do
    bytes = <<"VMCPICK", 1, 5023::32, rx::signed-32, rz::signed-32, rest::binary>>

    with {:ok, %{source: ^uuid, sequence: ^sequence} = request} <-
           PickupRequest.decode(bytes, {rx, rz}) do
      {:ok, %{kind: :pickup, key: {rx, rz}, request: request, inventory_digest: digest}}
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
        %{kind: :pickup, request: request, inventory_digest: digest},
        %{
          inventory: %Inventory{} = inventory,
          game_mode: %GameMode{current: mode}
        } = snapshot
      )
      when mode in [:survival, :adventure, :creative] do
    # Save files derive this permission from the saved mode, not a client flag.
    inventory = %{inventory | infinite_materials: mode == :creative}

    with {:ok, ^digest} <- inventory_digest(snapshot),
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

  defp inventory_digest(%{
         inventory: %Inventory{selected: selected} = inventory,
         game_mode: %GameMode{current: mode}
       })
       when selected in 0..8 and mode in [:survival, :adventure, :creative] do
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
           <<GameMode.id(mode), selected, if(inventory.table_inputs == nil, do: 0, else: 1)>>,
           bytes
         ])},
      else: {:error, :pickup_inventory_conflict}
  rescue
    _ -> {:error, :pickup_inventory_conflict}
  catch
    _, _ -> {:error, :pickup_inventory_conflict}
  end

  defp inventory_digest(_), do: {:error, :pickup_inventory_conflict}
end
