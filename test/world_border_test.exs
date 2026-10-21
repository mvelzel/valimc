defmodule Valimc.WorldBorderTest do
  use ExUnit.Case, async: true
  alias Valimc.Commands.WorldBorder, as: Command
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.World.{Border, BorderReplication, Clock, ClockRecord}

  test "a moving border steps once per tick, bounds trail by one step and it stops at its target" do
    border = Border.lerp(Border.new(), 100.0, 20.0, 4, 50)
    assert Border.size(border) == 100.0 and Border.lerp_target(border) == 20.0
    assert Border.lerp_time(border) == 4 and Border.status(border) == :shrinking
    assert Border.lerp_speed(border) == 20.0

    border = Border.tick(border)
    assert Border.size(border) == 80.0 and Border.lerp_time(border) == 3
    # Bounds (and collision, damage) use the previous step's size.
    assert Border.bounds(border) == {-50.0, -50.0, 50.0, 50.0}
    assert Border.snapshot(border).diameter == 100.0

    border = border |> Border.tick() |> Border.tick() |> Border.tick()
    assert border.extent == {:static, 20.0} and Border.status(border) == :stationary
    assert Border.bounds(border) == {-10.0, -10.0, 10.0, 10.0}
    assert Border.tick(border) == border
  end

  test "equal lerp sizes are stationary but announced as a lerp" do
    border = Border.lerp(Border.new(), 10.0, 10.0, 20, 0)
    assert border.extent == {:static, 10.0} and border.size_change == :lerp
    {_, [{id, _}]} = BorderReplication.reconcile(Border.new(), border)
    assert id == Data.id(:play, :clientbound, "set_border_lerp_size")
  end

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

  test "damage outside the border, its safe zone and the player box" do
    border = Border.new() |> Border.set_size(10.0)
    physics = Border.physics(border)
    # The whole box must be inside: 0.3 from the edge is still outside.
    assert Border.damage(physics, 4.69, 0.0) == 0.0
    assert Border.damage(physics, 4.75, 0.0) == 0.0
    # Within the 5-block safe zone: no damage.
    assert Border.damage(physics, 9.9, 0.0) == 0.0
    # Two blocks past the safe zone at 0.2 per block: at least 1.
    assert Border.damage(physics, 12.0, 0.0) == 1.0

    assert Border.damage(Border.physics(Border.set_damage_per_block(border, 2.0)), 12.0, 0.0) ==
             4.0

    assert Border.damage(Border.physics(Border.set_damage_per_block(border, 0.0)), 50.0, 0.0) ==
             0.0
  end

  test "players may interact with blocks whose corner is inside" do
    physics = Border.physics(Border.set_size(Border.new(), 10.0))
    assert Border.interactable?(physics, {-5, 64, 4})
    refute Border.interactable?(physics, {5, 64, 0})
    refute Border.interactable?(physics, {-6, 64, 0})
  end

  test "commands check the current state atomically" do
    border = Border.new()
    assert {:error, :same_size} = Border.command(border, {:set, Border.max_size(), 0}, 0)
    assert {:error, :too_big} = Border.command(border, {:add, 1.0, nil}, 0)
    border = Border.set_size(border, 100.0)
    assert {:error, :too_small} = Border.command(border, {:set, 0.5, 0}, 0)
    assert {:ok, moving, {_, 10.0, 20}} = Border.command(border, {:set, 10.0, 20}, 0)
    assert Border.lerp_time(moving) == 20
    # `add` with a time extends the remaining ticks; without one it is immediate.
    assert {:ok, longer, {_, _, 25}} = Border.command(moving, {:add, 5.0, 5}, 0)
    assert Border.lerp_time(longer) == 25
    assert {:ok, now, {_, _, 0}} = Border.command(moving, {:add, 5.0, nil}, 0)
    assert Border.status(now) == :stationary
    assert {:error, :too_far_out} = Border.command(border, {:center, 3.0e7, 0.0}, 0)
    assert {:error, :same_center} = Border.command(border, {:center, 0.0, 0.0}, 0)
    assert {:error, :same_warning_time} = Border.command(border, {:warning_time, 300}, 0)
  end

  test "observers get one packet per changed kind" do
    border = Border.new()
    {^border, [initialize]} = BorderReplication.reconcile(nil, border)
    assert elem(initialize, 0) == Data.id(:play, :clientbound, "initialize_border")

    changed = border |> Border.set_center(1.0, 2.0) |> Border.set_warning_time(40)
    {_, packets} = BorderReplication.reconcile(border, changed)

    assert Enum.map(packets, &elem(&1, 0)) == [
             Data.id(:play, :clientbound, "set_border_center"),
             Data.id(:play, :clientbound, "set_border_warning_delay")
           ]

    assert {_, []} = BorderReplication.reconcile(changed, Border.tick(changed))
    {_, [{_, body}]} = BorderReplication.reconcile(changed, Border.set_size(changed, 8.0))
    assert IO.iodata_to_binary(body) == <<8.0::float-64>>

    {_, [{_, body}]} =
      BorderReplication.reconcile(changed, Border.set_warning_blocks(changed, 300))

    assert IO.iodata_to_binary(body) == Wire.varint(300)
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

  test "Java fixed-point formatting rounds the shortest digits half up" do
    assert Command.fixed(0.20000000298023224, 2) == "0.20"
    assert Command.fixed(0.125, 2) == "0.13"
    assert Command.fixed(59_999_968.0, 0) == "59999968"
    assert Command.fixed(-0.001, 2) == "-0.00"
    assert Command.fixed(2.5, 0) == "3"
  end
end
