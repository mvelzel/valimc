defmodule Valimc.PlayerDropsTest do
  use ExUnit.Case, async: true
  alias Valimc.Living.{Freezing, Health}
  alias Valimc.{Inventory, ItemMotionState, PlayerDrops, PlayerTransfers}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack

  defp player(pose \\ :standing),
    do: %{x: 7.5, y: 64.0, z: 3.5, yaw: 0.0, pitch: 0.0, pose: pose}

  test "accepted posture controls launch origin while exact stacks and native motion enter the outbox" do
    stack = %{
      ItemStack.new("stone", 3)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    for {pose, eye} <- [{:crouching, 1.2699999809265137}] do
      assert {:ok, {0, 0}, [record]} = PlayerDrops.records(player(pose), [stack], :directed)
      assert record.stack == stack and record.x == 7.5 and record.z == 3.5
      assert record.y == 64.0 + eye - 0.30000001192092896
      assert PlayerDrops.at_source?(record, player())
      assert ItemMotionState.valid?(record.motion)
      assert record.motion.pickup_delay == 40 and not record.motion.no_gravity
      {x, y, z} = record.motion.velocity
      assert abs(x) <= 0.02 and y >= 0 and y <= 0.2 and z >= 0.28 and z <= 0.32
      source = PlayerState.capture(player(), %Inventory{slots: %{36 => stack}})
      target = %{source | inventory: %Inventory{}}

      assert {:ok, pending} =
               PlayerTransfers.prepare(<<77::128>>, 3, source, target, {0, 0}, [record])

      assert {:ok, bytes} = PlayerState.encode(<<77::128>>, pending)
      assert {:ok, restored} = PlayerState.decode(bytes, <<77::128>>)
      assert restored.outbox == pending.outbox
      assert restored.outbox.records == [record]
      assert {:ok, {0, 0}, request, _} = PlayerState.transfer_request(<<77::128>>, restored)
      assert request.records == [record] and request.sequence == 4
    end
  end

  test "death uses scattered upward launches while disconnected overflow uses directed motion" do
    stone = ItemStack.new("stone", 3)

    source =
      PlayerState.capture(
        Map.merge(player(), %{
          living: %Valimc.Living{freezing: %Freezing{}, health: %Health{}},
          motion: %Valimc.PlayerMotion{},
          game_mode: Valimc.GameMode.new(:survival),
          abilities: Valimc.PlayerAbilities.for_mode(:survival),
          last_death: nil
        }),
        %Inventory{slots: %{36 => stone}}
      )

    dead = put_in(source.health.value, 0.0)
    assert {:ok, after_death, {0, 0}, [record]} = PlayerTransfers.plan_death(dead)
    assert record.stack == stone and elem(record.motion.velocity, 1) == 0.20000000298023224

    assert {:ok, _} =
             PlayerTransfers.prepare_death(<<77::128>>, 0, dead, after_death, {0, 0}, [record])

    full = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})
    source = %{source | inventory: %Inventory{slots: full, carried: stone}}
    assert {:ok, _, {0, 0}, [record]} = PlayerTransfers.plan_disconnect(source)
    assert record.stack == stone and elem(record.motion.velocity, 2) >= 0.28
    assert record.motion.pickup_delay == 40
  end

  test "recipe drop authorization accepts the launch origin of a crouching player" do
    before = PlayerState.capture(player(), %Inventory{slots: %{1 => ItemStack.new("oak_log")}})
    {:ok, inventory, stacks} = Valimc.TestMenu.plan(before.inventory, :throw, 0, 0)
    assert {:ok, {0, 0}, [record]} = PlayerDrops.records(player(:crouching), stacks, :directed)
    after_snapshot = %{before | inventory: inventory}

    assert {:ok, pending} =
             Valimc.PlayerCraftingTransfers.prepare(
               <<77::128>>,
               0,
               before,
               after_snapshot,
               {0, 0},
               [record],
               {:throw, 0}
             )

    assert pending.outbox.records == [record]

    assert {:error, :invalid_crafting_transfer} =
             Valimc.PlayerCraftingTransfers.prepare(
               <<77::128>>,
               0,
               before,
               after_snapshot,
               {0, 0},
               [%{record | y: record.y + 0.1}],
               {:throw, 0}
             )
  end

  test "invalid origins, stacks and oversized cohorts refuse before source inventory mutation" do
    stone = ItemStack.new("stone")

    for {pose, stacks, kind} <- [
          {%{player() | y: 1_000_001}, [stone], :directed},
          {%{player() | pose: :unknown}, [stone], :directed},
          {player(), [nil], :directed},
          {player(), List.duplicate(stone, 6), :directed},
          {player(), [stone], :invalid}
        ],
        do: assert({:error, :invalid_player_drop} = PlayerDrops.records(pose, stacks, kind))

    assert {:ok, {0, 0}, []} = PlayerDrops.records(player(), [], :directed)
    assert {:ok, _, [record]} = PlayerDrops.records(%{player() | x: 0, z: 0}, [stone], :directed)
    assert PlayerDrops.at_source?(record, %{player() | x: 0, z: 0})
    refute PlayerDrops.at_source?(%{record | x: 1.0}, %{player() | x: 0, z: 0})
  end
end
