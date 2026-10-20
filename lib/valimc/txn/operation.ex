defmodule Valimc.Txn.Operation do
  @moduledoc """
  The per-kind half of a player-sourced transfer (VMC-064). A player snapshot
  holds at most one outbox; its kind selects an operation, and delivery, proof
  and resolution then run one generic path (`Valimc.TransferDelivery`,
  `Valimc.PlayerStore`):

  1. `request/2` rebuilds the pinned destination request from the outbox;
  2. `apply/2` delivers it to the destination owner (idempotent);
  3. `receipt/2` reads the destination's durable receipt for the source;
  4. `proof/4` turns that receipt into what this request's outcome was;
  5. `resolve/3` clears the outbox and applies the outcome to the snapshot.
  """

  alias Valimc.World.Region

  @callback request(uuid :: binary(), snapshot :: map()) ::
              {:ok, key :: term(), request :: map(), digest :: binary()} | {:error, term()}
  @callback apply(owner :: term(), request :: map()) :: {:ok, atom()} | {:error, term()}
  @callback receipt(owner :: term(), uuid :: binary()) ::
              {:ok, {term(), map()}} | {:error, term()}
  @callback proof(key :: term(), request :: map(), digest :: binary(), receipt :: map()) ::
              {:ok, term()} | {:error, term()}
  @callback resolve(uuid :: binary(), snapshot :: map(), proof :: term()) ::
              {:ok, map()} | {:error, term()}
  @doc "Whether a rejection completes the transfer (typed receipts can record one)."
  @callback rejectable?() :: boolean()
  @doc "The error a malformed outbox reports."
  @callback invalid() :: atom()

  @doc "The operation for a snapshot's outbox."
  def of(%{outbox: %{kind: :mining}}), do: __MODULE__.Mining
  def of(%{outbox: %{kind: :placement}}), do: __MODULE__.Placement
  def of(%{outbox: %{kind: :pickup}}), do: __MODULE__.Pickup
  def of(%{outbox: %{kind: :container}}), do: __MODULE__.Container
  def of(_), do: __MODULE__.Items

  @doc "Whether a delivery result ends the transfer (else it is retried or fails)."
  def completed?(_snapshot, {:ok, outcome}) when outcome in [:applied, :already_applied],
    do: true

  def completed?(snapshot, {:ok, outcome}) when outcome in [:rejected, :already_rejected],
    do: of(snapshot).rejectable?()

  def completed?(_snapshot, _result), do: false

  defmodule Items do
    @moduledoc false
    @behaviour Valimc.Txn.Operation
    def request(uuid, snapshot), do: Valimc.PlayerSnapshot.transfer_request(uuid, snapshot)
    def apply(owner, request), do: Region.apply_item_transfer(owner, request)
    def receipt(owner, uuid), do: Region.item_transfer_receipt(owner, uuid)

    def proof(_key, request, digest, receipt) do
      if receipt == %{sequence: request.sequence, digest: digest},
        do: {:ok, :applied},
        else: {:error, :transfer_receipt_conflict}
    end

    def resolve(_uuid, snapshot, :applied), do: {:ok, %{snapshot | outbox: nil}}
    def rejectable?, do: false
    def invalid, do: :invalid_transfer
  end

  defmodule Mining do
    @moduledoc false
    @behaviour Valimc.Txn.Operation

    def request(uuid, snapshot),
      do: Valimc.PlayerMiningIntent.request(uuid, snapshot.transfer_sequence, snapshot.outbox)

    def apply(owner, request), do: Region.apply_mining_transfer(owner, request)
    def receipt(owner, uuid), do: Region.item_transfer_receipt(owner, uuid)

    def proof(key, request, _digest, receipt),
      do: Valimc.World.MiningTransfers.receipt_result(key, request, receipt)

    def resolve(_uuid, snapshot, result),
      do: Valimc.PlayerMiningTransfers.resolve(snapshot, result)

    def rejectable?, do: true
    def invalid, do: :invalid_mining_transfer
  end

  defmodule Placement do
    @moduledoc false
    @behaviour Valimc.Txn.Operation

    def request(uuid, snapshot),
      do: Valimc.PlayerPlacementIntent.request(uuid, snapshot.transfer_sequence, snapshot.outbox)

    def apply(owner, request), do: Region.apply_placement_transfer(owner, request)
    def receipt(owner, uuid), do: Region.item_transfer_receipt(owner, uuid)

    def proof(key, request, _digest, receipt),
      do: Valimc.World.PlacementTransfers.receipt_result(key, request, receipt)

    def resolve(_uuid, snapshot, result),
      do: Valimc.PlayerPlacementTransfers.resolve(snapshot, result)

    def rejectable?, do: true
    def invalid, do: :invalid_placement_transfer
  end

  defmodule Pickup do
    @moduledoc false
    @behaviour Valimc.Txn.Operation

    def request(uuid, snapshot),
      do: Valimc.PlayerPickupIntent.request(uuid, snapshot.transfer_sequence, snapshot.outbox)

    def apply(owner, request), do: Region.apply_pickup_transfer(owner, request)
    def receipt(owner, uuid), do: Region.item_transfer_receipt(owner, uuid)

    def proof(key, request, _digest, receipt) do
      with {:ok, _} <- Valimc.World.PickupTransfers.receipt_result(key, request, receipt),
           do: {:ok, receipt}
    end

    def resolve(uuid, snapshot, receipt),
      do: Valimc.PlayerPickupTransfers.resolve(uuid, snapshot, receipt)

    def rejectable?, do: true
    def invalid, do: :invalid_pickup_request
  end

  defmodule Container do
    @moduledoc false
    @behaviour Valimc.Txn.Operation

    def request(uuid, snapshot),
      do: Valimc.PlayerContainerIntent.request(uuid, snapshot.transfer_sequence, snapshot.outbox)

    def apply(owner, request), do: Region.container_transfer(owner, request)
    def receipt(owner, uuid), do: Region.container_transfer_receipt(owner, uuid)

    def proof(key, request, _digest, receipt) do
      with {:ok, _} <- Valimc.World.ContainerTransfers.receipt_result(key, request, receipt),
           do: {:ok, receipt}
    end

    def resolve(uuid, snapshot, receipt),
      do: Valimc.PlayerContainerTransfers.resolve(uuid, snapshot, receipt)

    def rejectable?, do: true
    def invalid, do: :invalid_container_request
  end
end
