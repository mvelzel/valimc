defmodule Valimc.ImportedBlockEntitiesTest do
  @moduledoc "Imported block entities in a live region: owned chests, preserved signs (VMC-021e1)."
  use ExUnit.Case, async: true
  alias Valimc.Data.NBT
  alias Valimc.Blocks.BlockEntityTypes, as: Types
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.TestScope
  alias Valimc.World.{BlockEntities, Blocks, Containers, Region, RegionStorage}

  @sign BlockRegistry.default_state("oak_sign")
  @chest BlockRegistry.default_state("chest")

  setup do
    nonce = System.unique_integer([:positive])
    key = {88_000 + rem(nonce, 3_333) * 3, -1840}
    base = Path.join(System.tmp_dir!(), "valimc-imported-be-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {rx, rz} = key
    size = Valimc.Data.Grid.region_size()
    {cx, cz} = chunk = {rx * size + 1, rz * size + 2}
    sign = {cx * 16 + 3, 70, cz * 16 + 4}
    chest = {cx * 16 + 6, 70, cz * 16 + 4}

    {:ok, blocks} = Blocks.new(key)
    :ok = Blocks.put(blocks, %{sign => @sign, chest => @chest})
    {:ok, image} = Blocks.column_image(blocks, chunk)

    text =
      {:compound,
       %{
         "messages" => NBT.list(for line <- ["Imported", "", "", ""], do: {:string, line}),
         "color" => {:string, "black"},
         "has_glowing_text" => {:byte, 0}
       }}

    {sx, sy, sz} = sign

    {:ok, nbt} =
      BlockEntities.encode_nbt(
        {:compound,
         %{
           "id" => {:string, "minecraft:sign"},
           "x" => {:int, sx},
           "y" => {:int, sy},
           "z" => {:int, sz},
           "front_text" => text,
           "back_text" => text,
           "is_waxed" => {:byte, 0}
         }}
      )

    {:ok, containers, entry} = Containers.create(%Containers{}, key, chest, 3)
    slots = put_elem(entry.slots, 4, ItemStack.new("stone", 9))
    {:ok, containers, _} = Containers.replace(containers, chest, entry.revision, slots)

    :ok =
      RegionStorage.import(base, :overworld, key, %{
        columns: %{chunk => image},
        containers: containers,
        block_entities: %{sign => {Types.type_id(@sign), nbt}}
      })

    %{key: key, chunk: chunk, sign: sign, chest: chest}
  end

  defp payload(frame) do
    {_length, rest} = Wire.take_varint(frame)

    case Wire.take_varint(rest) do
      {0, body} -> body
      {_size, compressed} -> :zlib.uncompress(compressed)
    end
  end

  defp grant(position, secondary \\ false) do
    {x, y, z} = position
    # The 200 ms grant starts once its owner has no write in flight (VMC-073).
    {:ok, owner} =
      Valimc.TestWorld.existing_owner(
        Valimc.Data.Grid.region_key(Valimc.Data.Grid.chunk_key(x, z))
      )

    Valimc.TestWait.until(fn ->
      not Valimc.TestRegion.writing?(Valimc.TestRegion.section(owner))
    end)

    %{
      kind: :open,
      mode: :survival,
      eye: {x + 0.5, y + 1.5, z + 0.5},
      hand: :main,
      secondary: secondary,
      main: secondary,
      off: false,
      expires: Valimc.TestRegion.grant_expires(200)
    }
  end

  test "chunk packets carry the sign's update tag; changes and uses of it are refused", ctx do
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    frame = Valimc.TestWorld.chunk(ctx.chunk)
    body = payload(IO.iodata_to_binary(frame))
    assert :binary.match(body, "Imported") != :nomatch

    assert Valimc.TestBlocks.set(ctx.sign, 0) == {:error, :unsupported_block_entity}
    assert Valimc.TestBlocks.get(ctx.sign) == @sign

    assert {:error, :unsupported_block_entity} =
             Region.menu(owner, self(), ctx.sign, grant(ctx.sign))

    # A secondary use with an item does not reach the block in vanilla: it places.
    assert :pass = Region.menu(owner, self(), ctx.sign, grant(ctx.sign, true))
  end

  test "a refused change's correction can resend the sign's data", ctx do
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, packet} = Region.block_entity_update(owner, ctx.sign)
    {id, payload} = packet
    assert id == Valimc.Protocol.Data.id(:play, :clientbound, "block_entity_data")
    assert :binary.match(IO.iodata_to_binary(payload), "Imported") != :nomatch
    # Owned chests have no update tag; nothing is resent for them.
    assert Region.block_entity_update(owner, ctx.chest) == {:ok, nil}

    # Correction sends the block now; the data follows the acknowledgement.
    assert :ok = Region.correct_blocks(owner, [ctx.sign], self())
    sign = ctx.sign
    assert_receive {:event, {:block, ^sign, @sign}}
    refute_received {:event, {:block_entity, _, _}}
  end

  test "an imported chest opens with its contents", ctx do
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    assert {:chest, @chest, view} = Region.menu(owner, self(), ctx.chest, grant(ctx.chest))
    assert elem(view.slots, 4) == ItemStack.new("stone", 9)
  end
end
