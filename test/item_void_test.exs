defmodule Valimc.ItemVoidTest do
  use ExUnit.Case, async: true
  alias Valimc.{ItemMotionState, Protocol.ItemStack}
  alias Valimc.World.{ItemLedger, Items}

  test "the void threshold is strict and independent of lifetime, delay and gravity" do
    for minimum <- [-64, 0, 320],
        y <- [minimum - 65.0, minimum - 64.0, minimum - 63.0],
        motion <- [
          %ItemMotionState{},
          %ItemMotionState{age: -32768, pickup_delay: 32767, no_gravity: true}
        ] do
      record = %{
        uuid: <<1::128>>,
        x: 0.5,
        y: y,
        z: 0.5,
        stack: ItemStack.new("stone"),
        motion: motion
      }

      ledger = %ItemLedger{
        sequence: 12,
        incoming: %{{1, 0} => %{sequence: 7, digest: <<3::256>>}},
        generations: %{record.uuid => 4}
      }

      {:ok, items} = Items.restore({0, 0}, [record], ledger)
      {aged, expired} = Items.age(items, 1, minimum)
      assert expired != [] == y < minimum - 64
      assert map_size(aged.entries) == 1 and aged.ledger == ledger

      if expired != [] do
        [{epoch, id, revision}] = expired
        assert {:ok, removed} = Items.remove(aged, epoch, id, revision)
        assert removed.entries == %{} and removed.ledger.generations == %{}
        assert removed.ledger.sequence == 12 and removed.ledger.incoming == ledger.incoming
      end
    end
  end
end
