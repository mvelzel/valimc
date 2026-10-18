defmodule Valimc.PlayerContainerIntent do
  @moduledoc "Typed container journal binds original player items to one deterministic regional decision."
  alias Valimc.{GameMode, Inventory}
  alias Valimc.World.ContainerRequest
  def max_bytes, do: 8 + ContainerRequest.max_bytes()

  def bind(
        %{kind: :container, key: key, request: request} = intent,
        %{inventory: %Inventory{} = inventory, game_mode: %GameMode{current: mode}}
      )
      when map_size(intent) == 3 and mode in [:survival, :adventure, :creative] do
    infinite = mode == :creative
    reference = %{request | inventory: %{request.inventory | infinite_materials: infinite}}
    current = %{request | inventory: %{inventory | infinite_materials: infinite}}

    with {:ok, digest} <- ContainerRequest.digest(key, reference),
         {:ok, ^digest} <- ContainerRequest.digest(key, current) do
      {:ok, %{intent | request: current}}
    else
      _ -> {:error, :invalid_container_intent}
    end
  rescue
    _ -> {:error, :invalid_container_intent}
  end

  def bind(_, _), do: {:error, :invalid_container_intent}

  def encode(
        uuid,
        sequence,
        %{kind: :container, key: key, request: %{source: uuid, sequence: sequence} = request} =
          intent
      )
      when map_size(intent) == 3 do
    with {:ok, bytes} <- ContainerRequest.encode(key, request),
         do: {:ok, <<"VMCCOUT", 1, bytes::binary>>}
  end

  def encode(_, _, _), do: {:error, :invalid_container_intent}

  def decode(uuid, sequence, <<"VMCCOUT", 1, bytes::binary>>) do
    <<"VMCCREQ", 1, 5023::32, rx::signed-32, rz::signed-32, _::binary>> = bytes

    with {:ok, %{source: ^uuid, sequence: ^sequence} = request} <-
           ContainerRequest.decode(bytes, {rx, rz}) do
      {:ok, %{kind: :container, key: {rx, rz}, request: request}}
    else
      _ -> {:error, :invalid_container_intent}
    end
  rescue
    _ -> {:error, :invalid_container_intent}
  end

  def decode(_, _, _), do: {:error, :invalid_container_intent}

  def request(uuid, sequence, %{kind: :container, key: key, request: request} = intent) do
    with {:ok, _} <- encode(uuid, sequence, intent),
         {:ok, digest} <- ContainerRequest.digest(key, request),
         do: {:ok, key, request, digest}
  end

  def request(_, _, _), do: {:error, :invalid_container_intent}

  def inventory_result(%{key: key, request: request} = intent, %{
        inventory: %Inventory{} = inventory
      }) do
    current = %{
      request
      | inventory: %{inventory | infinite_materials: request.inventory.infinite_materials}
    }

    with {:ok, _} <- encode(request.source, request.sequence, intent),
         {:ok, digest} <- ContainerRequest.digest(key, request),
         {:ok, ^digest} <- ContainerRequest.digest(key, current),
         {:ok, _slots, next} <- ContainerRequest.plan(current) do
      {:ok, next}
    else
      _ -> {:error, :container_inventory_conflict}
    end
  rescue
    _ -> {:error, :container_inventory_conflict}
  end

  def inventory_result(_, _), do: {:error, :container_inventory_conflict}

  def matches_snapshot?(intent, snapshot),
    do: match?({:ok, _}, inventory_result(intent, snapshot))
end
