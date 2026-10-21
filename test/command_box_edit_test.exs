defmodule Valimc.CommandBoxEditTest do
  @moduledoc """
  Command block edits commit all or nothing across region owners (VMC-077o;
  commands audit E1–E3, E18): a part an owner refuses leaves every part as it
  was, `/clone … move` never clears a source whose destination is refused, a
  box edit's cells are locked against other writes until it commits, and
  unloaded positions are refused.
  """
  use ExUnit.Case, async: true
  alias Valimc.Command.Source
  alias Valimc.World
  alias Valimc.World.Region

  # Two regions side by side: x -512000..-511873 and -511872..-511745, z 896..1023.
  @keys [{-4000, 7}, {-3999, 7}]
  @y 70

  setup do
    owners =
      Map.new(@keys, fn key ->
        {:ok, owner} = World.owner(key)
        {key, owner}
      end)

    on_exit(fn ->
      for key <- @keys,
          registry <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(registry, key),
          do: Valimc.TestScope.kill(pid)
    end)

    %{owners: owners}
  end

  defp run(input) do
    source = %{Source.rcon() | dimension: :overworld, position: {-511_872.5, 70.0, 900.5}}
    Valimc.Commands.run(source, input)
    Source.collect(source)
  end

  defp block(name), do: Valimc.Registry.Blocks.default_state(name)

  # Lock one cell of the eastern region as another box edit would.
  defp lock(owners, position) do
    token = :crypto.strong_rand_bytes(16)
    owner = owners[{-3999, 7}]
    :ok = Region.prepare_box(owner, token, %{position => block("glass")}, %{}, %{})
    on_exit(fn -> Region.abort_box(owner, token) end)
    {owner, token}
  end

  test "a fill across two regions commits both or neither", %{owners: owners} do
    {owner, token} = lock(owners, {-511_871, @y, 900})
    output = run("fill -511875 #{@y} 900 -511870 #{@y} 900 stone")
    assert output =~ "box_edit_pending"
    # The western cells, which their own owner could have changed, stayed air.
    assert Valimc.TestBlocks.get({-511_875, @y, 900}) == block("air")
    # Other writes to a locked cell are refused until its edit ends.
    assert Valimc.TestBlocks.set({-511_871, @y, 900}, block("dirt")) ==
             {:error, :box_edit_pending}

    Region.abort_box(owner, token)
    assert run("fill -511875 #{@y} 900 -511870 #{@y} 900 stone") =~ "Successfully filled 6 block"

    for x <- -511_875..-511_870,
        do: assert(Valimc.TestBlocks.get({x, @y, 900}) == block("stone"))
  end

  test "clone … move keeps its source when the destination is refused", %{owners: owners} do
    assert run("setblock -511875 #{@y} 910 gold_block") =~ "Changed the block"
    lock(owners, {-511_871, @y, 910})
    output = run("clone -511875 #{@y} 910 -511875 #{@y} 910 -511871 #{@y} 910 replace move")
    assert output =~ "box_edit_pending"
    assert Valimc.TestBlocks.get({-511_875, @y, 910}) == block("gold_block")
    assert Valimc.TestBlocks.get({-511_871, @y, 910}) == block("air")
  end

  test "read_box reads what single-cell reads do (native parity)" do
    :ok = Valimc.TestBlocks.set({-511_873, @y, 920}, block("dirt"))
    :ok = Valimc.TestBlocks.set({-511_872, @y + 1, 921}, block("glass"))
    {min, max} = {{-511_874, @y, 920}, {-511_871, @y + 1, 921}}
    {:ok, read} = World.BoxEdit.read(:overworld, min, max)
    assert map_size(read) == 16

    for {position, state} <- read, do: assert(Valimc.TestBlocks.get(position) == state)
    assert read[{-511_873, @y, 920}] == block("dirt")
    assert read[{-511_872, @y + 1, 921}] == block("glass")
  end

  test "positions in regions that are not loaded are refused" do
    assert run("setblock 9000000 70 9000000 stone") =~ "That position is not loaded"

    assert run("fill 9000000 70 9000000 9000001 70 9000000 stone") =~
             "That position is not loaded"

    refute Enum.any?(Registry.lookup(Valimc.RegionRegistry, {70_312, 70_312}))
  end
end
