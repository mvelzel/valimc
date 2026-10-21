defmodule Valimc.TableAccessTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{TableAccess, World}
  alias Valimc.Protocol.Data
  alias Valimc.World.Region

  test "block-owner decisions precede its later block publications and fence epoch/deadline" do
    key = {88_500, 958}
    {:ok, {pid, epoch} = owner} = World.owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)
    end)

    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span + 1, 64, rz * span + 1}
    {x, y, z} = position
    table = Data.item_block(Data.item("crafting_table"))
    :ok = World.set_block(position, table)

    grant = %{
      kind: :open,
      mode: :survival,
      eye: {x + 0.5, y + 1.5, z + 0.5},
      hand: :main,
      secondary: false,
      main: false,
      off: false,
      expires: Valimc.TestRegion.grant_expires(500)
    }

    World.subscribe(MapSet.new([key]), MapSet.new())
    ref = make_ref()
    assert :ok = Region.request_table(owner, self(), ref, position, grant)
    :ok = World.set_block(position, 0)
    assert_receive {:event, first}
    assert first == {:table_admitted, ref, owner, :open}
    assert_receive {:event, {:block, ^position, 0}}

    ref = make_ref()
    click = %{grant | kind: :click, expires: Valimc.TestRegion.grant_expires(500)}
    assert :ok = Region.request_table(owner, self(), ref, position, click)
    assert_receive {:event, {:table_admitted, ^ref, ^owner, {:error, :invalid_table_context}}}
    :ok = World.set_block(position, table)
    assert_receive {:event, {:block, ^position, ^table}}

    for {target, grant, expected} <- [
          {{pid, make_ref()}, grant, :stale_owner},
          {owner, %{grant | expires: System.monotonic_time(:millisecond) - 1},
           :expired_table_grant}
        ] do
      ref = make_ref()
      assert :ok = Region.request_table(target, self(), ref, position, grant)
      assert_receive {:event, {:table_admitted, ^ref, ^owner, {:error, ^expected}}}
    end

    assert elem(owner, 1) == epoch
    assert World.get_block(position) == table
    assert TableAccess.authorize(table, position, %{}, 0) == {:error, :invalid_table_grant}
    refute TableAccess.opens?(:survival, :off, false, false, false)
  end
end
