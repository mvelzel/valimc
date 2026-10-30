defmodule Valimc.MobPathRegionTest do
  @moduledoc """
  Paths in an owner (VMC-041b): a mob's search runs as the section's job
  over published snapshots and its path arrives on a later tick. A piglin
  sees gold between the posts of a fence line, which it cannot cross: it
  walks around the line's end and takes the gold. A search across a section
  line reads the next section's snapshots; its result goes stale when one
  of the chunks it read is published again, and a pending path nothing
  answers is given up.
  """
  use ExUnit.Case, async: true
  alias Valimc.AI.{Navigation, Self, World}
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.{MobPaths, Region}

  describe "in an owner" do
    setup do
      nonce = System.unique_integer([:positive])
      key = {68_000 + rem(nonce, 333) * 3, 2911}
      base = Path.join(System.tmp_dir!(), "valimc-mob-path-#{nonce}")

      TestScope.isolate(TestScope.neighborhood(key),
        world_path: base,
        item_simulation: true,
        region_ticks: :manual,
        # These read Elixir brains (activities, memories): their mobs stay
        # Elixir (VMC-081d; the native brains' think parity compares them).
        native_mob_types:
          Application.get_env(:valimc, :native_mob_types) --
            ~w(minecraft:piglin minecraft:hoglin minecraft:villager minecraft:iron_golem minecraft:wandering_trader minecraft:cat)
      )

      File.mkdir_p!(base)
      Valimc.TestDisk.write(base, key, :items, %{records: []})
      {:ok, owner} = Valimc.TestWorld.item_owner(key)
      {rx, rz} = key
      # The section's west line: a floor east of it, and a strip of the
      # next section's west of it (nowhere to stroll to there).
      {x0, z0} = {rx * 128, rz * 128 + 40}
      stone = Valimc.Data.Blocks.default_state("stone")

      for x <- x0..(x0 + 10),
          z <- (z0 - 4)..(z0 + 8),
          do: Valimc.TestBlocks.set({x, 63, z}, stone)

      for z <- z0..(z0 + 4), do: Valimc.TestBlocks.set({x0 - 1, 63, z}, stone)

      on_exit(fn ->
        for k <- TestScope.neighborhood(key), {pid, _} <- Valimc.TestWorld.registered(k) do
          try do
            :sys.resume(pid)
            TestScope.kill(pid)
          catch
            :exit, _ -> :ok
          end
        end

        File.rm_rf(base)
      end)

      %{key: key, owner: owner, at: {x0, z0}}
    end

    defp step(ctx, ticks) do
      {pid, _} = ctx.owner
      TestScope.simulate(pid, ctx.key)
      for _ <- 1..ticks, do: Region.step({pid, nil}, 1)
    end

    defp store(ctx), do: Valimc.TestRegion.section(ctx.owner).entities.store

    defp fence(cells) do
      fence = Valimc.Data.Blocks.default_state("oak_fence")
      for {x, z} <- cells, do: Valimc.TestBlocks.set({x, 64, z}, fence)
    end

    # A piglin at `from` sees a gold ingot at `to`: the paths it follows
    # (while in this section), tick by tick, until it holds the ingot.
    defp fetch_gold(ctx, {px, pz}, {ix, iz}) do
      {:ok, piglin} = Body.new("minecraft:piglin")
      :ok = Region.drop_items(ctx.owner, [Store.body_record(piglin, <<31::128>>, {px, 64.0, pz})])

      ingot = %{
        uuid: <<32::128>>,
        x: ix,
        y: 64.0,
        z: iz,
        stack: ItemStack.new("gold_ingot"),
        motion: %Valimc.Entity.ItemMotionState{on_ground: true}
      }

      :ok = Region.drop_items(ctx.owner, [ingot])
      gold = Valimc.Protocol.ItemTypes.id("gold_ingot")

      Stream.repeatedly(fn ->
        step(ctx, 1)

        case Store.find(store(ctx), <<31::128>>) do
          {:ok, {_, id, _}} ->
            body = store(ctx).entries[id].body

            case {body.mob.equipment[:offhand], body.mob.ai.navigation.path} do
              {%{item_id: ^gold}, _} -> :took
              {_, %{nodes: nodes}} -> Tuple.to_list(nodes)
              _ -> []
            end

          # In the sibling section for now.
          _ ->
            []
        end
      end)
      |> Stream.take(2000)
      |> Stream.transform(false, fn
        _, true -> {:halt, true}
        :took, _ -> {[:took], true}
        nodes, _ -> {[nodes], false}
      end)
    end

    test "a piglin walks around a fence line to the gold it sees", ctx do
      {x0, z0} = ctx.at
      fence(for z <- (z0 - 4)..(z0 + 3), do: {x0 + 5, z})
      paths = Enum.to_list(fetch_gold(ctx, {x0 + 4.5, z0 + 0.5}, {x0 + 8.5, z0 + 1.5}))
      assert List.last(paths) == :took
      nodes = List.flatten(paths -- [:took])
      # Around the line's end, never through it.
      assert Enum.any?(nodes, fn {_, _, z} -> z > z0 + 3 end)
      refute Enum.any?(nodes, fn {x, _, z} -> x == x0 + 5 and z <= z0 + 3 end)
    end

    test "a search across the section line reads the next one's snapshots, fenced", ctx do
      {x0, z0} = ctx.at
      fence(for x <- x0..(x0 + 10), do: {x, z0 + 2})
      air = Valimc.Data.Blocks.default_state("air")
      read = &Valimc.World.View.block(Valimc.World.View.new(:overworld), &1)
      world = %World{read: read, time: 100}
      self = %{self_in(world) | x: x0 + 1.5, z: z0 + 0.5}
      {_, self} = Navigation.move_to(self, {x0 + 2.5, 64.0, z0 + 4.5}, 1.0)
      paths = MobPaths.queue(%MobPaths{}, [%{effects: self.effects}])
      {:ok, _, _, work} = MobPaths.next(paths, %Valimc.World.Jobs{}, :overworld)
      [{key, {path, _, chunks}, fence} = result] = work.()

      # Around the fence's west end, in the next section, to within a block.
      assert path.reached and path.target == {x0 + 2, 64, z0 + 4}
      assert Enum.any?(Tuple.to_list(path.nodes), fn {x, _, _} -> x < x0 end)
      assert {Bitwise.bsr(x0 - 1, 4), Bitwise.bsr(z0, 4)} in chunks
      assert length(fence) == length(chunks)
      assert %{^key => {^path, _, _}} = MobPaths.done(%MobPaths{}, [result], :overworld).ready

      # The next section's chunk published again: the result is stale.
      Valimc.TestBlocks.set({x0 - 1, 70, z0}, Valimc.Data.Blocks.default_state("stone"))
      Valimc.TestBlocks.set({x0 - 1, 70, z0}, air)
      assert %{^key => :stale} = MobPaths.done(%MobPaths{}, [result], :overworld).ready
    end
  end

  defp self_in(world) do
    mind = Valimc.AI.mind("minecraft:zombie", <<41::128>>, nil)
    {:ok, body} = Body.new("minecraft:zombie")

    %Self{
      id: 1,
      uuid: <<41::128>>,
      type: "minecraft:zombie",
      x: 0.5,
      y: 64.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      head: 0.0,
      on_ground: true,
      mob: body.mob,
      mind: mind,
      facts: Valimc.AI.Facts.mob("minecraft:zombie"),
      width: 0.6000000238418579,
      height: 1.9500000476837158,
      eye: 1.7400000095367432,
      world: world
    }
  end

  test "a deferred path is pending, then installed, stale or given up" do
    stone = Valimc.Data.Blocks.default_state("stone")
    air = Valimc.Data.Blocks.default_state("air")
    world = %World{read: fn {_, y, _} -> if y < 64, do: stone, else: air end, time: 100}
    {started, self} = Navigation.move_to(self_in(world), {6.5, 64.0, 0.5}, 1.0)
    assert started
    assert %{pending: 1} = self.mind.navigation.path
    assert [{:path, <<41::128>>, 1, request}] = self.effects
    assert request.targets == [{6, 64, 0}] and request.evaluator == :walk
    refute Navigation.done?(self.mind.navigation)

    # The owner keeps the newest request per mob.
    paths = MobPaths.queue(%MobPaths{}, [%{effects: self.effects}])
    assert paths.order == [<<41::128>>]

    # A chunk published since the search read it: stale, and recomputed.
    results = [{{<<41::128>>, 1}, {nil, 0, [{0, 0}]}, [{{0, 0}, make_ref()}]}]
    {ready, _} = MobPaths.take(MobPaths.done(%MobPaths{}, results, :overworld))
    assert ready == %{{<<41::128>>, 1} => :stale}
    later = %{self | effects: [], world: %{world | paths: ready, time: 200}}
    again = Navigation.receive(later)
    assert %{pending: 2} = again.mind.navigation.path

    # A current result is installed, trimmed as followed.
    path = %{
      nodes: {{0, 64, 0}, {1, 64, 0}},
      types: {2, 2},
      index: 0,
      target: {6, 64, 0},
      reached: false
    }

    installed =
      Navigation.receive(%{
        later
        | world: %{later.world | paths: %{{<<41::128>>, 1} => {path, 0, []}}}
      })

    assert installed.mind.navigation.path == path

    # Nothing within the limit: given up.
    nav = %{self.mind.navigation | tick: 41}
    gone = Navigation.receive(%{self | mind: %{self.mind | navigation: nav}})
    assert gone.mind.navigation.path == nil
  end
end
