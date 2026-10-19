defmodule Valimc.World.StoreImportTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.World.{ItemLedger, MiningRecord, Store}

  @moduletag :tmp_dir

  test "legacy files with a pending mining journal import the journal's outcome once", %{
    tmp_dir: base
  } do
    key = {812, 813}
    {x, z} = {812 * 128 + 1, 813 * 128 + 1}
    TestScope.isolate(key, world_path: base)

    try do
      File.write!(
        Store.block_path(base, key),
        :erlang.term_to_binary({:valimc_region, 1, %{{x, 70, z} => 1}})
      )

      {:ok, items} = ItemLedger.encode(key, [], %{})
      File.write!(Store.item_path(base, key), items)
      # An interrupted legacy commit: the journal mined the block, files not yet replaced.
      {:ok, journal} = MiningRecord.encode(key, %{{x, 70, z} => 0}, items)
      File.write!(Store.mining_path(base, key), journal)

      {:ok, writer, lease} = Store.open(key)
      assert Store.load(writer) == %{}
      :ok = Store.close(writer, lease)

      assert Store.durable(base, key, :blocks) == %{}
      assert File.exists?(Store.block_path(base, key) <> ".v1")
      refute File.exists?(Store.mining_path(base, key))

      # Reopening reads the log, not the retired legacy files.
      {:ok, writer, lease} = Store.open(key)
      assert Store.load(writer) == %{}
      :ok = Store.close(writer, lease)
    after
    end
  end
end
