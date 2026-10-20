defmodule Valimc.World.ContainerPermitsTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{ContainerPermits, ItemReceipts}

  defp fixture(source \\ <<1::128>>, sequence \\ 7, token \\ <<2::128>>) do
    {:ok, receipts, _} = ItemReceipts.reserve(%{}, source)

    {receipts, %{source: source, sequence: sequence, permit: token, position: {0, 64, 0}},
     <<3::256>>}
  end

  defp consume(permits, request, digest, now) do
    {permits, grant} = ContainerPermits.take(permits, request, now)
    {permits, ContainerPermits.eligible?(grant, request, digest)}
  end

  test "a reserved source receives one exact single-use action grant" do
    {receipts, request, digest} = fixture()
    {:ok, permits} = ContainerPermits.issue(Valimc.Txn.Permits.new(), receipts, request, digest, 100)

    assert {:error, :container_already_pending} =
             ContainerPermits.issue(
               permits,
               receipts,
               %{request | permit: <<4::128>>},
               digest,
               101
             )

    assert {empty, true} = consume(permits, request, digest, 5099)
    assert empty.entries == %{}
    assert {^empty, false} = consume(empty, request, digest, 5099)
  end

  test "expiry includes its exact boundary and replacement has no surviving authority" do
    {receipts, request, digest} = fixture()
    {:ok, permits} = ContainerPermits.issue(Valimc.Txn.Permits.new(), receipts, request, digest, -100)

    assert {%Valimc.Txn.Permits{entries: entries}, false} =
             consume(permits, request, digest, 4900)

    assert entries == %{}

    assert {%Valimc.Txn.Permits{entries: %{}}, false} =
             consume(Valimc.Txn.Permits.new(), request, digest, 0)

    assert {:ok, _} = ContainerPermits.issue(permits, receipts, request, digest, 4900)
  end

  test "altered payload or sequence burns its source token; another source cannot steal it" do
    {receipts, request, digest} = fixture()
    {:ok, permits} = ContainerPermits.issue(Valimc.Txn.Permits.new(), receipts, request, digest, 0)

    assert {^permits, false} =
             consume(permits, %{request | source: <<99::128>>}, digest, 1)

    for {changed, changed_digest} <- [{request, <<9::256>>}, {%{request | sequence: 8}, digest}] do
      assert {%Valimc.Txn.Permits{entries: entries}, false} =
               consume(permits, changed, changed_digest, 1)

      assert entries == %{}
    end
  end

  test "missing, invalid or advanced receipt slots never issue speculative grants" do
    {receipts, request, digest} = fixture()

    for receipts <- [
          %{},
          Map.put(receipts, request.source, %{sequence: 0, digest: <<1>>}),
          Map.put(receipts, request.source, %{sequence: 7, digest: <<0::256>>})
        ] do
      assert {:error, :invalid_container_permit} =
               ContainerPermits.issue(Valimc.Txn.Permits.new(), receipts, request, digest, 0)
    end

    for {request, digest} <- [
          {%{}, digest},
          {%{request | sequence: -1}, digest},
          {request, <<1>>}
        ] do
      assert {:error, :invalid_container_permit} =
               ContainerPermits.issue(Valimc.Txn.Permits.new(), receipts, request, digest, 0)
    end
  end

  test "a target block edit invalidates authority even when its state is replaced identically" do
    {receipts, request, digest} = fixture()
    {:ok, permits} = ContainerPermits.issue(Valimc.Txn.Permits.new(), receipts, request, digest, 0)
    assert Valimc.Txn.Permits.invalidate(permits, %{{1, 64, 0} => 0}) == permits
    invalidated = Valimc.Txn.Permits.invalidate(permits, %{request.position => 1234})
    assert invalidated.entries == %{}
    assert {^invalidated, false} = consume(invalidated, request, digest, 1)
  end

  test "the owner bounds active grants and reclaims only expired or explicitly released entries" do
    permits =
      Enum.reduce(1..128, Valimc.Txn.Permits.new(), fn i, permits ->
        {receipts, request, digest} = fixture(<<i::128>>, 7, <<i::128>>)
        {:ok, next} = ContainerPermits.issue(permits, receipts, request, digest, 0)
        next
      end)

    {receipts, request, digest} = fixture(<<129::128>>, 7, <<129::128>>)

    assert {:error, :container_permits_full} =
             ContainerPermits.issue(permits, receipts, request, digest, 1)

    assert Valimc.Txn.Permits.release(permits, <<1::128>>, <<2::128>>) == permits
    released = Valimc.Txn.Permits.release(permits, <<1::128>>, <<1::128>>)
    assert map_size(released.entries) == 127
    assert {:ok, _} = ContainerPermits.issue(released, receipts, request, digest, 1)

    assert {:ok, %Valimc.Txn.Permits{entries: entries}} =
             ContainerPermits.issue(permits, receipts, request, digest, 5000)

    assert map_size(entries) == 1
  end
end
