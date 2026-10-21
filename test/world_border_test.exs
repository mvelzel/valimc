defmodule Valimc.WorldBorderTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Border, Clock, ClockRecord}
  alias Valimc.Physics.BorderSnapshot

  test "saved settings keep a moving border's remaining ticks" do
    border =
      Border.new()
      |> Border.set_center(12.5, -3.0)
      |> Border.set_warning_blocks(7)
      |> Border.lerp(64.0, 32.0, 10, 0)
      |> Border.tick()
      |> Border.tick()

    assert byte_size(Border.encode(border)) == Border.settings_bytes()
    {:ok, loaded} = Border.decode(Border.encode(border), 900)
    assert loaded.center_x == 12.5 and loaded.warning_blocks == 7
    assert Border.size(loaded) == Border.size(border) and Border.lerp_time(loaded) == 8
    assert Border.lerp_target(loaded) == 32.0
    assert {:error, _} = Border.decode(<<0::64*8>> <> <<0>>, 0)
    assert {:error, _} = Border.decode(<<3.0e7::float-64, 0::64*8>>, 0)
  end

  test "players may interact with blocks whose corner is inside" do
    physics = Border.physics(Border.set_size(Border.new(), 10.0))
    assert Border.interactable?(physics, {-5, 64, 4})
    refute Border.interactable?(physics, {5, 64, 0})
    refute Border.interactable?(physics, {-6, 64, 0})
  end

  test "clock records save borders and read version 4 records with the default" do
    data = ClockRecord.new()
    border = data.borders["minecraft:overworld"] |> Border.lerp(30.0, 10.0, 100, 0)
    data = %{data | borders: Map.put(data.borders, "minecraft:overworld", border)}
    {:ok, bytes} = ClockRecord.encode(data)
    {:ok, loaded} = ClockRecord.decode(bytes)
    assert Border.lerp_time(loaded.borders["minecraft:overworld"]) == 100
    assert Border.lerp_target(loaded.borders["minecraft:overworld"]) == 10.0

    # A version 4 record is the same body without the border entries.
    body_size = byte_size(bytes) - 32
    <<body::binary-size(^body_size), _::binary>> = bytes
    <<"VMCLOCK", 5, rest::binary>> = binary_part(body, 0, byte_size(body) - 1 - 1 - 19 - 64)
    old = <<"VMCLOCK", 4, rest::binary>>
    {:ok, loaded} = ClockRecord.decode(old <> :crypto.hash(:sha256, old))
    assert loaded.borders == %{"minecraft:overworld" => Border.new()}
  end

  test "the owner applies border commands atomically" do
    clock =
      start_supervised!({Clock, name: :border_test_clock, world_path: nil, tick_interval_ms: nil})

    assert {:ok, {_, 16.0, 0}} =
             Clock.border_command({:set, 16.0, 0}, "minecraft:overworld", clock)

    assert {:error, :same_size} =
             Clock.border_command({:set, 16.0, 0}, "minecraft:overworld", clock)

    assert {:error, :unknown_dimension} =
             Clock.border_command({:set, 2.0, 0}, "minecraft:moon", clock)

    assert Border.size(Clock.snapshot(clock).borders["minecraft:overworld"]) == 16.0

    # Each dimension has its own border (VMC-026b), the default until changed.
    refute Map.has_key?(Clock.snapshot(clock).borders, "minecraft:the_nether")

    assert {:ok, {_, 64.0, 0}} =
             Clock.border_command({:set, 64.0, 0}, "minecraft:the_nether", clock)

    borders = Clock.snapshot(clock).borders
    assert Border.size(borders["minecraft:the_nether"]) == 64.0
    assert Border.size(borders["minecraft:overworld"]) == 16.0
    refute Map.has_key?(borders, "minecraft:the_end")
  end

  test "malformed observations and queries remain explicit failures" do
    for values <- [{nil, 0, 8, 32}, {0, 0, -1, 32}, {0, 0, 8, -1}, {0, 0, 8, 32.0}] do
      assert {:error, :invalid_border_observation} =
               apply(BorderSnapshot, :new, Tuple.to_list(values))
    end

    for border <- [
          nil,
          %BorderSnapshot{diameter: :unknown},
          Map.put(%BorderSnapshot{}, :extra, true)
        ] do
      assert {:error, :invalid_border_observation} = BorderSnapshot.bounds(border)
    end

    assert {:error, :invalid_border_query} = BorderSnapshot.contains?(%BorderSnapshot{}, nil)

    assert {:error, :invalid_border_query} =
             BorderSnapshot.distance(%BorderSnapshot{}, {:unknown, 0})

    assert {:error, :invalid_border_query} =
             BorderSnapshot.no_collision?(%BorderSnapshot{}, {nil, 0}, {0, 0, 0, 1, 1, 1})

    assert {:error, :invalid_border_query} =
             BorderSnapshot.no_collision?(%BorderSnapshot{}, nil, nil)
  end
end
