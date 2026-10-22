# Storage cost per action (VMC-077f): bytes written and latency of a pickup, a
# chest click and a block edit in a populated region (128 items, 64 filled
# chests), and the cold load time of a region with 20,000 edited cells.
#
#   MIX_ENV=bench mix run --no-start bench/storage_actions.exs <scratch-dir> [results.json]
#
# Bytes are the growth of every file under the world folder over the actions,
# after a flush, with checkpoints paused (as `/save-off`): what the actions
# append to the log. Latency is the owner call a player's group makes for it
# (VMC-077i3: a pickup and a click are plain calls in the player's owner).
defmodule Bench.StorageActions do
  alias Valimc.Player.GameMode
  alias Valimc.Menus.Inventory
  alias Valimc.World
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, Region, RegionStorage}

  @chest hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])

  def bytes(base) do
    Path.wildcard(Path.join(base, "**"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sum_by(&File.stat!(&1).size)
  end

  def origin({rx, rz}), do: {rx * 128, rz * 128}

  # 128 items and 64 chests of 27 stacks each, written as the region's import.
  def populate(base, key) do
    {ox, oz} = origin(key)

    records =
      for i <- 1..128,
          do: %{
            uuid: <<rx(key)::32, 0::32, i::64>>,
            x: ox + 2.5 + rem(i, 32) * 3,
            y: 64.0,
            z: oz + 2.5 + div(i, 32) * 3,
            stack: ItemStack.new("stone", 1 + rem(i, 60)),
            motion: %Valimc.Entity.ItemMotionState{no_gravity: true}
          }

    positions = for i <- 0..63, do: {ox + 4 + rem(i, 16) * 6, 70, oz + 40 + div(i, 16) * 6}

    containers =
      Enum.reduce(positions, %Containers{}, fn position, acc ->
        {:ok, acc, entry} = Containers.create(acc, key, position, 3)
        slots = List.to_tuple(for s <- 0..26, do: ItemStack.new("cobblestone", 1 + s))
        {:ok, acc, _} = Containers.replace(acc, position, entry.revision, slots)
        acc
      end)

    # Filled chests keep their blocks: the import holds both.
    :ok =
      RegionStorage.import(base, :overworld, key, %{
        items: records,
        containers: containers,
        cells: Map.new(positions, &{&1, @chest})
      })

    {:ok, owner} = World.item_owner(Valimc.World.section(:overworld, key, :section))
    %{owner: owner, records: records, positions: positions, containers: containers}
  end

  defp rx({rx, _}), do: rx

  def stop(key, pid) do
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
    Valimc.TestWaitless.await_gone(key)
  end

  def pickup(owner, uuid, inventory, item) do
    actor = %{
      uuid: uuid,
      entity_id: 1,
      box: {item.x - 0.3, item.y, item.z - 0.3, item.x + 0.3, item.y + 1.8, item.z + 0.3},
      game_mode: GameMode.new(:survival),
      health: %{value: 20.0}
    }

    {:ok, inventory, _taken} = Region.take_item(owner, actor, item.uuid, inventory)
    inventory
  end

  def click(owner, position, inventory) do
    {x, y, z} = position

    actor = %{
      mode: :survival,
      eye: {x + 0.5, y + 1.6, z + 0.5},
      position: {x + 0.5, y, z + 0.5},
      health: 20.0,
      expires: System.monotonic_time(:millisecond) + 200
    }

    click = %{inventory: inventory, action: :pickup, slot: 0, button: 0}

    {:ok, inventory, _, _} =
      Region.container_click(owner, self(), make_ref(), position, actor, click)

    inventory
  end

  def median(times), do: Enum.at(Enum.sort(times), div(length(times), 2)) / 1000

  def run(base) do
    key = {9700, 9700}
    %{owner: owner, records: records, positions: positions} = populate(base, key)
    {pid, _} = owner
    uuid = <<9700::128>>
    flush = fn -> :ok = Region.flush(pid) end
    flush.()
    Valimc.World.Saving.set_auto(false)

    # Pickups.
    before = bytes(base)

    {_inventory, pickups} =
      records
      |> Enum.take(20)
      |> Enum.reduce({%Inventory{}, []}, fn item, {inventory, times} ->
        started = System.monotonic_time(:microsecond)
        inventory = pickup(owner, uuid, inventory, item)
        {inventory, [System.monotonic_time(:microsecond) - started | times]}
      end)

    flush.()
    pickup_bytes = div(bytes(base) - before, 20)

    # Chest clicks: each takes the first stack of a chest into the cursor and
    # the next click puts nothing back (a fresh chest each time).
    before = bytes(base)

    clicks =
      for position <- Enum.take(positions, 20) do
        started = System.monotonic_time(:microsecond)
        _inventory = click(owner, position, %Inventory{})
        System.monotonic_time(:microsecond) - started
      end

    flush.()
    click_bytes = div(bytes(base) - before, 20)

    # Block edits: one cell each, as creative placement commits it.
    {ox, oz} = origin(key)
    before = bytes(base)

    edits =
      for i <- 1..200 do
        position = {ox + rem(i, 100), 90 + div(i, 100), oz + 100}
        {:ok, view} = Region.observe_blocks(owner, [position])
        started = System.monotonic_time(:microsecond)
        {:ok, _} = Region.set_blocks(owner, view.fence, %{position => 1})
        System.monotonic_time(:microsecond) - started
      end

    flush.()
    edit_bytes = div(bytes(base) - before, 200)
    Valimc.World.Saving.set_auto(true)

    # An edited region: 20,000 cells, then cold loads.
    for batch <-
          Enum.chunk_every(
            for(x <- 0..99, z <- 0..99, y <- [100, 101], do: {ox + x, y, oz + z}),
            128
          ) do
      {:ok, view} = Region.observe_blocks(owner, batch)
      {:ok, _} = Region.set_blocks(owner, view.fence, Map.new(batch, &{&1, 1}))
    end

    flush.()

    loads =
      for _ <- 1..3 do
        {pid, _} = elem(World.owner(Valimc.World.section(:overworld, key, :section)), 1)
        stop(key, pid)
        started = System.monotonic_time(:microsecond)
        {:ok, _} = World.owner(Valimc.World.section(:overworld, key, :section))
        System.monotonic_time(:microsecond) - started
      end

    %{
      pickup: %{bytes_per_action: pickup_bytes, median_ms: median(pickups)},
      click: %{bytes_per_action: click_bytes, median_ms: median(clicks)},
      block_edit: %{bytes_per_action: edit_bytes, median_ms: median(edits)},
      edited_region_load: %{median_ms: median(loads), cells: 20_000}
    }
  end
end

defmodule Valimc.TestWaitless do
  def await_gone(key) do
    if Registry.lookup(Valimc.RegionRegistry, Valimc.World.section(:overworld, key, :section)) !=
         [] do
      Process.sleep(1)
      await_gone(key)
    end
  end
end

[base | rest] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :item_simulation, false)
Application.put_env(:valimc, :cooking_simulation, false)
{:ok, _} = Application.ensure_all_started(:valimc)
result = Bench.StorageActions.run(base)

json =
  :json.encode(%{
    workload: "storage cost per action; 128 items and 64 filled chests in the region",
    commit: String.trim(elem(System.cmd("git", ["rev-parse", "--short", "HEAD"]), 0)),
    schedulers: System.schedulers_online(),
    results: result
  })

IO.puts(json)
if rest != [], do: File.write!(hd(rest), json)
