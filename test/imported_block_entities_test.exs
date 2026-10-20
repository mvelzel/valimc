defmodule Valimc.ImportedBlockEntitiesTest do
  @moduledoc "Imported block entities in a live region: owned chests, preserved signs (VMC-021e1)."
  use ExUnit.Case, async: true
  alias Valimc.NBT
  alias Valimc.Physics.BlockEntities, as: Types
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.Registry.Blocks, as: BlockRegistry
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.{BlockEntities, Blocks, Containers, Region, Store}

  @sign BlockRegistry.default_state("oak_sign")
  @chest BlockRegistry.default_state("chest")

  setup do
    nonce = System.unique_integer([:positive])
    key = {88_000 + rem(nonce, 10_000), -1840}
    base = Path.join(System.tmp_dir!(), "valimc-imported-be-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(reg, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {rx, rz} = key
    size = Valimc.config(:region_size)
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
    {:ok, bytes} = Containers.encode(key, containers)

    :ok =
      Store.import_region(base, key, %{
        columns: %{chunk => image},
        containers: bytes,
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

    %{
      kind: :open,
      mode: :survival,
      eye: {x + 0.5, y + 1.5, z + 0.5},
      hand: :main,
      secondary: secondary,
      main: secondary,
      off: false,
      expires: System.monotonic_time(:millisecond) + 200
    }
  end

  test "chunk packets carry the sign's update tag; changes and uses of it are refused", ctx do
    {:ok, owner} = World.owner(ctx.key)
    frame = World.chunk(ctx.chunk)
    body = payload(IO.iodata_to_binary(frame))
    assert :binary.match(body, "Imported") != :nomatch

    assert World.set_block(ctx.sign, 0) == {:error, :unsupported_block_entity}
    assert World.get_block(ctx.sign) == @sign

    World.subscribe(MapSet.new([ctx.key]), MapSet.new())
    ref = make_ref()
    assert :ok = Region.request_table(owner, self(), ref, ctx.sign, grant(ctx.sign))

    assert_receive {:event, {:table_admitted, ^ref, ^owner, {:error, :unsupported_block_entity}}}

    # A secondary use with an item does not reach the block in vanilla: it places.
    ref = make_ref()
    assert :ok = Region.request_table(owner, self(), ref, ctx.sign, grant(ctx.sign, true))
    assert_receive {:event, {:table_admitted, ^ref, ^owner, :pass}}
  end

  test "a refused change's correction resends the sign's data after its block", ctx do
    {:ok, owner} = World.owner(ctx.key)
    {:ok, packet} = Region.block_entity_update(owner, ctx.sign)
    {id, payload} = packet
    assert id == Valimc.Protocol.Data.id(:play, :clientbound, "block_entity_data")
    assert :binary.match(IO.iodata_to_binary(payload), "Imported") != :nomatch
    # Owned chests have no update tag; nothing is resent for them.
    assert Region.block_entity_update(owner, ctx.chest) == {:ok, nil}

    assert :ok = Region.correct_blocks(owner, [ctx.sign], self())
    sign = ctx.sign
    assert_receive {:event, {:block, ^sign, @sign}}
    assert_receive {:event, {:block_entity, ^sign, ^packet}}
  end

  test "an imported chest opens with its contents", ctx do
    {:ok, owner} = World.owner(ctx.key)
    World.subscribe(MapSet.new([ctx.key]), MapSet.new())
    ref = make_ref()
    assert :ok = Region.request_table(owner, self(), ref, ctx.chest, grant(ctx.chest))
    assert_receive {:event, {:table_admitted, ^ref, ^owner, {:chest, @chest, view}}}
    assert elem(view.slots, 4) == ItemStack.new("stone", 9)
  end
end
