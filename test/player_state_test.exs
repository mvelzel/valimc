defmodule Valimc.Player.StateTest do
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, Inventory, PlayerFood, PlayerProgression}
  alias Valimc.Living
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack
  alias Valimc.Storage.Checkpoint

  @uuid <<27::128>>

  defp patched,
    do: %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"persist" => {:string, "unchanged"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

  defp inventory,
    do: %Inventory{
      slots: %{
        1 => ItemStack.new("egg", 3),
        5 => ItemStack.new("diamond_helmet"),
        9 => patched(),
        36 => ItemStack.new("stone", 23),
        45 => ItemStack.new("shield")
      },
      selected: 2,
      carried: patched(),
      table_inputs: List.to_tuple([ItemStack.new("oak_planks", 3) | List.duplicate(nil, 8)]),
      state_id: 32767,
      infinite_materials: true,
      drag: %{type: 2, targets: MapSet.new([9, 10])}
    }

  defp player do
    %{
      x: -3.25,
      y: 64.0,
      z: 17.75,
      yaw: 123.5,
      pitch: -25.0,
      game_mode: GameMode.new(:survival),
      abilities: %Valimc.PlayerAbilities{flying: false},
      living:
        Map.merge(
          elem(Living.restore(%{health: %{value: 13.5, hurt_ticks: 4, death_ticks: 0}}), 1),
          %{absorption: 4.0, fire_ticks: 80, air_supply: 120}
        ),
      food: %PlayerFood{level: 17, saturation: 1.5, exhaustion: 0.25, timer: 12},
      progression: %PlayerProgression{},
      motion: %Valimc.PlayerMotion{fall_distance: 2.5, velocity: {0.0, -0.0784, 0.0}},
      last_death: {4, 63, -2},
      dimension: :the_nether,
      death_dimension: :overworld,
      portal_cooldown: 300,
      seen_credits: true
    }
  end

  test "a state round-trips every durable field, but not the session's authority" do
    state = PlayerState.capture(player(), inventory())
    assert {:ok, bytes} = PlayerState.encode(@uuid, state)
    assert {:ok, restored} = PlayerState.decode(bytes, @uuid)

    assert restored == %{
             state
             | inventory: %{inventory() | state_id: 0, infinite_materials: false, drag: nil}
           }

    assert restored.absorption == 4.0 and restored.fire_ticks == 80 and restored.seen_credits
  end

  test "another format, another player's file and a changed byte are refused" do
    {:ok, bytes} = PlayerState.encode(@uuid, PlayerState.capture(player(), inventory()))
    assert PlayerState.decode(bytes, <<28::128>>) == {:error, :invalid_player_file}
    <<head::binary-size(40), byte, rest::binary>> = bytes
    flipped = <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>
    assert PlayerState.decode(flipped, @uuid) == {:error, :invalid_player_file}

    assert PlayerState.decode("VMCPOSE" <> :binary.copy(<<0>>, 120), @uuid) ==
             {:error, :invalid_player_file}

    # A file missing a field is not filled with defaults (D4: one format).
    {:ok, %{records: records}} = Checkpoint.decode(bytes)
    partial = IO.iodata_to_binary(Checkpoint.encode(0, Map.delete(records, {:player, :food})))
    assert PlayerState.decode(partial, @uuid) == {:error, :invalid_player_file}
  end

  test "every field is checked before it is written" do
    base = PlayerState.capture(player(), inventory())
    slot0 = %{base | inventory: %{base.inventory | slots: %{0 => ItemStack.new("stone")}}}

    huge =
      ItemStack.new("stone")
      |> Map.put(:components, %{
        "minecraft:custom_data" =>
          {:compound, %{"b" => {:byte_array, :binary.copy(<<1>>, 600_000)}}}
      })

    for {state, reason} <- [
          {slot0, :invalid_inventory},
          {%{base | inventory: %{base.inventory | selected: 9}}, :invalid_inventory},
          {%{base | inventory: %{base.inventory | slots: %{1 => huge}}}, :invalid_inventory},
          {%{base | health: %{value: -1.0, hurt_ticks: 0, death_ticks: 0}}, :invalid_health},
          {%{base | food: %PlayerFood{level: 99}}, :invalid_food},
          {%{base | dimension: :moon}, :invalid_dimension}
        ] do
      assert PlayerState.encode(@uuid, state) == {:error, reason}
    end
  end

  test "an open crafting table's grid round-trips with the inventory" do
    grid = List.to_tuple([ItemStack.new("oak_planks", 3) | List.duplicate(nil, 8)])
    state = PlayerState.capture(player(), %{inventory() | table_inputs: grid})
    assert {:ok, bytes} = PlayerState.encode(@uuid, state)
    assert {:ok, %{inventory: %{table_inputs: ^grid}}} = PlayerState.decode(bytes, @uuid)
  end
end
