defmodule Valimc.BlockBatchTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.World
  alias Valimc.World.{BlockBatch, Blocks, Region}
  alias Valimc.TestClient, as: Client

  test "preparation bounds positions, registry states, count and one-region scope" do
    assert {:ok, batch} =
             BlockBatch.prepare(%{
               {-1, -64, -1} => 0,
               {-16, 319, -16} => Data.block_state_count() - 1
             })

    assert batch.region == {-1, -1}
    assert batch.chunks == [{-1, -1}]

    for bad <- [
          %{},
          [],
          %{{0, 64, 0} => Data.block_state_count()},
          %{{0, 64, 0} => -1},
          %{{0.0, 64, 0} => 1},
          %{{0, 320, 0} => 1},
          %{{0, -65, 0} => 1},
          %{{30_000_000, 64, 0} => 1},
          %{{0, 64, 0} => 1, {1, 64, 0} => :stone},
          Map.new(0..4096, &{{rem(&1, 128), 64 + div(&1, 128), 0}, 1})
        ] do
      assert {:error, :invalid_block_batch} = BlockBatch.prepare(bad)
    end

    assert {:error, :cross_region_batch} =
             BlockBatch.prepare(%{{-1, 64, 0} => 1, {0, 64, 0} => 1})
  end

  test "owner commits one revision and publication, invalidating each touched chunk once" do
    {pid, epoch} = owner = region({400, 401})
    {x, z} = {400 * 128, 401 * 128}
    changes = %{{x, 64, z} => 1, {x + 1, 65, z} => 2, {x + 16, 80, z} => 3}

    for key <- [
          {div(x, 16), div(z, 16)},
          {div(x, 16) + 1, div(z, 16)},
          {div(x, 16) + 2, div(z, 16)}
        ],
        do: World.chunk(key)

    before = Valimc.TestConn.state(pid).resource
    World.subscribe(MapSet.new([{400, 401}]), MapSet.new())
    assert {:ok, revision} = Region.set_blocks(owner, before.revision, changes)
    assert revision == before.revision + 1

    assert {:ok, %{blocks: ^changes, revision: ^revision}} =
             Region.observe_blocks(owner, Map.keys(changes), revision)

    after_commit = Valimc.TestConn.state(pid).resource
    assert map_size(after_commit.cache) == 1

    assert after_commit.versions == %{
             {div(x, 16), div(z, 16)} => 1,
             {div(x, 16) + 1, div(z, 16)} => 1
           }

    assert_receive {:event, {:block_batch, frames}}
    assert length(frames) == 2 and Enum.all?(frames, fn {_, frame} -> is_binary(frame) end)
    refute_receive {:event, _}, 10

    for {target, rev, edits, error} <- [
          {{pid, make_ref()}, revision, changes, :stale_owner},
          {owner, before.revision, changes, :stale_revision},
          {owner, revision, %{{x + 128, 64, z} => 1}, :wrong_region},
          {owner, revision, Map.put(changes, {x + 2, 64, z}, -1), :invalid_block_batch}
        ] do
      assert {:error, ^error} = Region.set_blocks(target, rev, edits)
      assert mutation_state(pid) == mutation_state(after_commit)
      refute_receive {:event, _}, 10
    end

    assert epoch == after_commit.items.epoch
  end

  test "compressed TCP sends only section frames for the recipient's loaded chunks" do
    name = "Batch" <> Integer.to_string(System.unique_integer([:positive]))
    {_, client} = Client.login(name)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    {:ok, owner} = World.owner({0, 0})
    changes = %{{0, 64, 2} => 1, {1, 65, 2} => 2, {16, 64, 2} => 3, {32, 64, 2} => 4}
    {:ok, before} = Region.observe_blocks(owner, Map.keys(changes))

    on_exit(fn ->
      with {:ok, current} <- Region.observe_blocks(owner, []),
           do: Region.set_blocks(owner, current.revision, before.blocks)
    end)

    assert {:ok, _} = Region.set_blocks(owner, before.revision, changes)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {received, _} = collect_updates(client, [])
    {:ok, batch} = BlockBatch.prepare(changes)

    expected =
      for {{cx, _}, frame} <- batch.frames, cx <= 1 do
        {:ok, _, body, <<>>} = Wire.next_frame(frame, 2_097_152, client.threshold)
        body
      end

    assert Enum.sort(received) == Enum.sort(expected)
    assert length(received) == 2
  end

  test "a blocked owner cannot serialize a different owner's batch" do
    {slow, _} = first = region({404, 405})
    second = region({406, 407})
    :sys.suspend(slow)

    try do
      pending =
        Task.async(fn -> Region.set_blocks(first, 0, %{{404 * 128, 64, 405 * 128} => 1}) end)

      assert Task.yield(pending, 10) == nil
      assert {:ok, 1} = Region.set_blocks(second, 0, %{{406 * 128, 64, 407 * 128} => 1})
      :sys.resume(slow)
      assert Task.await(pending, 1000) == {:ok, 1}
    after
      :sys.resume(slow)
    end
  end

  defp region(key) do
    {:ok, {pid, _} = owner} = World.owner(key)
    on_exit(fn -> DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid) end)
    owner
  end

  defp mutation_state(pid) when is_pid(pid),
    do: mutation_state(Valimc.TestConn.state(pid).resource)

  defp mutation_state(state),
    do:
      state
      |> Map.take([:cache, :versions, :revision, :dirty])
      |> Map.put(:image, Blocks.image(state.blocks))

  defp collect_updates(client, received) do
    {id, body, client} = Client.read(client)

    case Data.name(:play, :clientbound, id) do
      "section_blocks_update" -> collect_updates(client, [body | received])
      "system_chat" -> {received, client}
      name -> collect_updates(Client.auto_reply(client, :play, name, body), received)
    end
  end
end
