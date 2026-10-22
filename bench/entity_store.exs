# Entity store costs (VMC-077h): how many items one region holds, the bytes
# the log takes per entity change, and the packet encodes per tick for moving
# items, alone and with observers pulling them like connections do.
#
#   mix run --no-start bench/entity_store.exs <scratch-dir> [results.json]
#
# Bytes are the growth of the world folder over the changes after a flush,
# with checkpoints paused, so what the changes append to the log. Encodes are
# calls into `Valimc.Protocol.EntityPackets` (every entity packet built), per
# 50 ms tick.
defmodule Bench.EntityStore do
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.{Region, RegionStorage}

  def bytes(base) do
    Path.wildcard(Path.join(base, "**"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sum_by(&File.stat!(&1).size)
  end

  def position({rx, rz}, i),
    do: {rx * 128 + 2.5 + rem(i, 120), 64.0, rz * 128 + 2.5 + div(i, 120) * 0.5}

  def records({rx, rz} = key, count, mode) do
    for i <- 1..count do
      {x, _, z} = position(key, i)

      %{
        uuid: <<rx::32, rz::32, i::64>>,
        stack: ItemStack.new("stone", 1 + rem(i, 60)),
        x: x,
        y: if(mode == :moving, do: 70.0, else: 64.0),
        z: z,
        motion: %ItemMotionState{
          velocity: if(mode == :moving, do: {0.05, 0.0, 0.0}, else: {0.0, 0.0, 0.0}),
          no_gravity: true,
          on_ground: mode == :resting
        }
      }
    end
  end

  # Items one region accepts before refusing.
  def capacity(key) do
    {:ok, owner} = World.item_owner(Valimc.World.section(:overworld, key, :section))

    Enum.reduce_while(1..2000, 0, fn i, created ->
      case Region.create_item(owner, ItemStack.new("dirt"), position(key, i)) do
        {:ok, _} -> {:cont, created + 1}
        {:error, reason} -> {:halt, {created, reason}}
      end
    end)
    |> case do
      {created, reason} -> %{items: created, refusal: inspect(reason)}
      created -> %{items: created, refusal: nil}
    end
  end

  def persistence(base, key) do
    :ok = RegionStorage.import(base, :overworld, key, %{items: records(key, 200, :resting)})
    {:ok, {pid, _} = owner} = World.item_owner(Valimc.World.section(:overworld, key, :section))
    flush = fn -> :ok = Region.flush(pid) end
    flush.()
    Valimc.World.Saving.set_auto(false)

    measure = fn fun ->
      before = bytes(base)
      fun.()
      flush.()
      div(bytes(base) - before, 20)
    end

    created =
      measure.(fn ->
        for i <- 1..20,
            do:
              {:ok, _} = Region.create_item(owner, ItemStack.new("dirt"), position(key, 500 + i))
      end)

    handles =
      for i <- 1..20,
          do: elem(Region.find_item(owner, <<elem(key, 0)::32, elem(key, 1)::32, i::64>>), 1)

    replaced =
      measure.(fn ->
        for handle <- handles, do: {:ok, _} = Region.replace_item(handle, ItemStack.new("egg", 3))
      end)

    handles =
      for i <- 1..20,
          do: elem(Region.find_item(owner, <<elem(key, 0)::32, elem(key, 1)::32, i::64>>), 1)

    removed = measure.(fn -> for handle <- handles, do: :ok = Region.remove_item(handle) end)
    Valimc.World.Saving.set_auto(true)
    %{create: created, replace: replaced, remove: removed}
  end

  def encodes(base, key, observers) do
    :ok = RegionStorage.import(base, :overworld, key, %{items: records(key, 200, :moving)})
    {:ok, owner} = World.item_owner(Valimc.World.section(:overworld, key, :section))
    chunks = Valimc.World.RegionGeneration.chunks_of(key)
    :ok = Region.ticket(owner, :forced, hd(chunks), chunks)
    Process.sleep(500)
    owner_only = count(fn -> Process.sleep(2000) end)
    replication = Valimc.Entity.Observer.new()
    states = for _ <- 1..observers, do: {replication, %{}}

    {total, observer_us} =
      count_timed(fn ->
        Enum.reduce(1..40, {states, 0}, fn _, {states, us} ->
          {elapsed, states} =
            :timer.tc(fn ->
              for {replication, cache} <- states do
                {desired, cache} =
                  World.visible_entities(
                    [World.section(:overworld, key, :section)],
                    chunks,
                    cache
                  )

                {replication, _packets} =
                  Valimc.Entity.Observer.reconcile(
                    replication,
                    desired,
                    &World.entity_frames/2
                  )

                {replication, cache}
              end
            end)

          Process.sleep(50)
          {states, us + elapsed}
        end)
      end)

    %{
      items: 200,
      observers: observers,
      owner_encodes_per_tick: Float.round(owner_only / 40, 1),
      with_observers_encodes_per_tick: Float.round(total / 40, 1),
      observer_us_per_tick: div(observer_us, 40)
    }
  end

  defp count(fun) do
    :erlang.trace_pattern({Valimc.Protocol.EntityPackets, :_, :_}, true, [:call_count])
    fun.()
    total = total()
    :erlang.trace_pattern({Valimc.Protocol.EntityPackets, :_, :_}, false, [:call_count])
    total
  end

  defp count_timed(fun) do
    :erlang.trace_pattern({Valimc.Protocol.EntityPackets, :_, :_}, true, [:call_count])
    {_states, us} = fun.()
    total = total()
    :erlang.trace_pattern({Valimc.Protocol.EntityPackets, :_, :_}, false, [:call_count])
    {total, us}
  end

  defp total do
    for {name, arity} <- Valimc.Protocol.EntityPackets.__info__(:functions), reduce: 0 do
      acc ->
        case :erlang.trace_info({Valimc.Protocol.EntityPackets, name, arity}, :call_count) do
          {:call_count, n} when is_integer(n) -> acc + n
          _ -> acc
        end
    end
  end
end

[base | rest] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :cooking_simulation, false)
{:ok, _} = Application.ensure_all_started(:valimc)

results = %{
  capacity: Bench.EntityStore.capacity({9800, 9800}),
  bytes_per_change: Bench.EntityStore.persistence(base, {9802, 9800}),
  encodes: Bench.EntityStore.encodes(base, {9804, 9800}, 16)
}

json =
  :json.encode(%{
    workload:
      "entity store: capacity, log bytes per change, encodes per tick (200 moving items, 16 observers)",
    commit: String.trim(elem(System.cmd("git", ["rev-parse", "--short", "HEAD"]), 0)),
    schedulers: System.schedulers_online(),
    results: results
  })

IO.puts(json)
if rest != [], do: File.write!(hd(rest), json)
