defmodule Valimc.PendingCookingAwardsTest do
  use ExUnit.Case, async: true
  alias Valimc.{Cooking, Inventory}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, ContainerTransfers}
  @recipe "minecraft:iron_ingot_from_smelting_raw_iron"
  @key {0, 0}
  @pos {0, 64, 0}
  @source <<1::128>>

  defp fixture do
    {:ok, cs, entry} = Containers.create_cooking(%Containers{}, @key, @pos, :furnace)
    cooking = %Cooking{slots: {nil, nil, ItemStack.new("iron_ingot", 4)}, total: 200}

    {:ok, cs, entry} =
      Containers.replace_cooking(cs, @pos, entry.revision, cooking, %{@recipe => 7})

    {:ok, cs, _} = ContainerTransfers.reserve(cs, @source)

    req = %{
      source: @source,
      sequence: 1,
      permit: <<4::128>>,
      position: @pos,
      revision: entry.revision,
      kind: :furnace,
      slots: cooking.slots,
      inventory: %Inventory{},
      action: :pickup,
      slot: 2,
      button: 1
    }

    {cs, req, %{position: {0.5, 64.0, -0.5}, draws: %{@recipe => 0}}}
  end

  test "legacy versions keep exact bytes and never invent pending awards" do
    {:ok, chest, _} = Containers.create(%Containers{}, @key, @pos, 3)
    {:ok, typed, _} = ContainerTransfers.reserve(chest, @source)
    {cooking, _, _} = fixture()

    # Original d4e5e59 encoder hashes, retained before the v4 extension.
    for {version, state, hash} <- [
          {1, chest, "3b92014792c633cb7f7f1feb969c43933dd55e094b87fab5ddad9d618ac905e2"},
          {2, typed, "ac67ffa682d7e130f444210f959bd7ac02ae2726fd7e28b735db4289430171e7"},
          {3, cooking, "cd0de3321bf9c0efbc6582a033cb061e93abf918e71615b1770d33a5da57d1f2"}
        ] do
      assert {:ok, <<"VMCCONTS", ^version, _::binary>> = bytes} = Containers.encode(@key, state)
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == hash
      assert {:ok, decoded} = Containers.decode(bytes, @key)
      assert decoded == state and decoded.pending_awards == %{}
      assert {:ok, ^bytes} = Containers.encode(@key, decoded)
    end
  end
end
