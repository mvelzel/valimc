defmodule Valimc.ItemMergeTransferTest do
  use ExUnit.Case, async: true
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.ItemMergeTransfer, as: Transfer

  defp request do
    donor = %{
      uuid: <<1::128>>,
      x: 127.9,
      y: 64.0,
      z: 8.5,
      stack: ItemStack.new("stone", 2),
      motion: %ItemMotionState{age: 30, pickup_delay: 10}
    }

    recipient = %{
      donor
      | uuid: <<2::128>>,
        x: 128.1,
        stack: ItemStack.new("stone", 3),
        motion: %ItemMotionState{age: 100, pickup_delay: 2}
    }

    %{
      source: {0, 0},
      destination: {1, 0},
      sequence: 7,
      permit: <<3::128>>,
      donor: donor,
      recipient: recipient,
      donor_generation: 2,
      recipient_generation: 4
    }
  end

  test "canonical transfer retains exact owned records and independent generations across either boundary" do
    first = request()

    negative = %{
      first
      | source: {-1, 0},
        destination: {0, 0},
        donor: %{first.donor | x: -0.1},
        recipient: %{first.recipient | x: 0.1}
    }

    for proposal <- [first, negative] do
      assert {:ok, bytes} = Transfer.encode(proposal)
      assert byte_size(bytes) <= Transfer.max_bytes()
      assert {:ok, ^proposal} = Transfer.decode(bytes)

      assert {:ok, %{stack: %{count: 5}, donor_stack: nil, motion: motion}} =
               Transfer.decision(proposal)

      assert motion.age == 30 and motion.pickup_delay == 10
      assert {:ok, digest} = Transfer.digest(proposal)
      assert digest == :crypto.hash(:sha256, bytes)
    end
  end

  test "malformed, oversized, noncanonical and wrong ownership records refuse" do
    proposal = request()
    assert {:ok, bytes} = Transfer.encode(proposal)

    for bad <- [
          <<>>,
          bytes <> <<0>>,
          binary_part(bytes, 0, byte_size(bytes) - 1),
          :binary.copy(<<0>>, Transfer.max_bytes() + 1)
        ] do
      assert {:error, :invalid_item_merge_transfer} = Transfer.decode(bad)
    end

    for bad <- [
          Map.put(proposal, :extra, true),
          %{proposal | source: proposal.destination},
          %{proposal | sequence: 0},
          %{proposal | sequence: 18_446_744_073_709_551_616},
          %{proposal | donor_generation: 18_446_744_073_709_551_615},
          %{proposal | recipient_generation: -1},
          %{proposal | permit: <<0>>},
          %{proposal | donor: %{proposal.donor | x: 128.1}},
          %{proposal | recipient: %{proposal.recipient | uuid: proposal.donor.uuid}},
          %{proposal | donor: Map.put(proposal.donor, :untrusted, true)}
        ] do
      assert {:error, :invalid_item_merge_transfer} = Transfer.encode(bad)
    end
  end
end
