defmodule Valimc.MobPathRegionTest do
  @moduledoc """
  Paths in an owner (VMC-041b): a piglin sees gold between the posts of a
  fence line, which it cannot cross: it walks around the line's end and
  takes the gold.
  """
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.Region

  describe "in an owner" do
    setup do
      nonce = System.unique_integer([:positive])
      key = {68_000 + rem(nonce, 333) * 3, 2911}
      base = Path.join(System.tmp_dir!(), "valimc-mob-path-#{nonce}")

      TestScope.isolate(TestScope.neighborhood(key),
        world_path: base,
        item_simulation: true,
        region_ticks: :manual
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
            entry = store(ctx).entries[id]
            body = Valimc.TestBodies.body(entry)

            case {body.mob.equipment[:offhand], Valimc.TestBodies.path(entry)} do
              {%{item_id: ^gold}, _} -> :took
              {_, nodes} when is_list(nodes) -> nodes
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
  end
end
