defmodule Valimc.CommandConnectionTest do
  use ExUnit.Case, async: false
  # Drives player commands over sockets (VMC-053b); messages are vanilla keys.
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.Wire

  defp name(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  defp command(client, input, key) do
    Client.send_packet(client, :play, "chat_command", Wire.string(input))
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, key) != :nomatch, "#{input}: #{inspect(body)}"
    client
  end

  defp pid(player_name), do: Enum.find(Valimc.Players.all(), &(&1.name == player_name)).pid

  defp count(pid, item) do
    id = Valimc.Protocol.ItemTypes.id(item)

    :sys.get_state(pid).inventory
    |> Valimc.Inventory.contents()
    |> Enum.filter(&(&1 && &1.item_id == id))
    |> Enum.map(& &1.count)
    |> Enum.sum()
  end

  # Vanilla's chat throttle kicks after about ten quick commands, so each test
  # session stays below that.
  defp join do
    player = name("Cmd")
    {_, client} = Client.login(player)
    on_exit(fn -> Client.close(client) end)
    {Client.load_world(client), pid(player)}
  end

  test "an operator's own game mode and items" do
    {client, pid} = join()

    client = command(client, "gamemode survival", "commands.gamemode.success.self")
    assert :sys.get_state(pid).player.game_mode.current == :survival
    assert :sys.get_state(pid).inventory.infinite_materials == false

    client = command(client, "give @s minecraft:diamond 70", "commands.give.success.single")
    assert count(pid, "diamond") == 70
    client = command(client, "give @s diamond 6401", "commands.give.failed.toomanyitems")
    client = command(client, "clear @s diamond 10", "commands.clear.success.single")
    assert count(pid, "diamond") == 60
    client = command(client, "clear @s diamond 0", "commands.clear.test.single")
    _client = command(client, "clear @s minecraft:stone", "clear.failed.single")
  end

  test "an operator's own experience, effects, teleport and death" do
    {client, pid} = join()

    client =
      command(client, "xp add @s 3 levels", "commands.experience.add.levels.success.single")

    assert :sys.get_state(pid).player.progression.experience.level == 3
    client = command(client, "xp set @s 100 points", "commands.experience.set.points.invalid")
    client = command(client, "xp query @s levels", "commands.experience.query.levels")

    client = command(client, "effect give @s speed 10 1", "commands.effect.give.success.single")

    assert Map.has_key?(
             :sys.get_state(pid).player.effects,
             Valimc.Protocol.EffectTypes.id("speed")
           )

    client = command(client, "effect clear @s", "commands.effect.clear.everything.success.single")
    client = command(client, "effect clear @s", "commands.effect.clear.everything.failed")

    client = command(client, "tp @s 3 70 4", "commands.teleport.success.location.single")
    assert %{x: 3.5, y: 70.0, z: 4.5} = Map.take(:sys.get_state(pid).player, [:x, :y, :z])
    client = command(client, "tp 0 30000000 0", "commands.teleport.invalidPosition")

    _client = command(client, "kill", "commands.kill.success.single")
    assert :sys.get_state(pid).life_stage != :alive
  end

  test "commands reach other players through their own connections" do
    first = name("Op")
    second = name("Target")
    {_, a} = Client.login(first)
    on_exit(fn -> Client.close(a) end)
    {_, b} = Client.login(second)
    on_exit(fn -> Client.close(b) end)
    a = Client.load_world(a)
    b = Client.load_world(b)

    _a = command(a, "gamemode adventure #{second}", "commands.gamemode.success.other")
    {body, _b} = Client.await(b, :play, "system_chat")
    assert :binary.match(body, "gameMode.changed") != :nomatch
    assert :sys.get_state(pid(second)).player.game_mode.current == :adventure
  end

  test "world commands: clocks, weather, difficulty, game rules and blocks" do
    {client, _pid} = join()
    before = Valimc.World.Clock.snapshot()
    {difficulty, _} = Valimc.World.Clock.difficulty()

    on_exit(fn ->
      Valimc.World.Clock.configure(
        {"minecraft:overworld", :ticks, before.clocks["minecraft:overworld"].total_ticks}
      )

      Valimc.World.Clock.configure({:advance_time, before.advance_time})
      Valimc.World.Clock.configure({:difficulty, difficulty.level, true})
    end)

    client = command(client, "time set 1234", "commands.time.set.absolute")
    assert Valimc.World.Clock.snapshot().clocks["minecraft:overworld"].total_ticks == 1234
    client = command(client, "time set 1234", "commands.time.set.already_at_time")
    client = command(client, "time set noon", "commands.time.set.time_marker")
    assert Valimc.World.Clock.snapshot().clocks["minecraft:overworld"].total_ticks == 6000
    client = command(client, "weather rain 600", "commands.weather.set.rain")
    level = if difficulty.level == 3, do: "easy", else: "hard"
    client = command(client, "difficulty #{level}", "commands.difficulty.success")
    client = command(client, "difficulty #{level}", "commands.difficulty.failure")
    value = not before.advance_time
    _client = command(client, "gamerule advance_time #{value}", "commands.gamerule.set")
    assert Valimc.World.Clock.snapshot().advance_time == value
  end

  test "setblock and fill change blocks through their region owners" do
    {client, _pid} = join()
    stone = Valimc.Registry.Blocks.default_state("stone")
    glass = Valimc.Registry.Blocks.default_state("glass")
    client = command(client, "setblock 40 100 40 stone", "commands.setblock.success")
    assert Valimc.World.get_block({40, 100, 40}) == stone
    client = command(client, "setblock 40 100 40 stone", "commands.setblock.failed")
    client = command(client, "setblock 40 100 40 glass keep", "commands.setblock.failed")
    client = command(client, "fill 40 101 40 42 103 42 glass hollow", "commands.fill.success")
    assert Valimc.World.get_block({40, 101, 40}) == glass
    assert Valimc.World.get_block({41, 102, 41}) == Valimc.Registry.Blocks.default_state("air")

    client =
      command(client, "fill 40 101 40 42 103 42 stone replace glass", "commands.fill.success")

    assert Valimc.World.get_block({42, 103, 42}) == stone
    _client = command(client, "fill 0 0 0 40 40 40 stone", "commands.fill.toobig")
  end

  test "say, msg and list reach every player" do
    first = name("Talk")
    second = name("Hear")
    {_, a} = Client.login(first)
    on_exit(fn -> Client.close(a) end)
    {_, b} = Client.login(second)
    on_exit(fn -> Client.close(b) end)
    a = Client.load_world(a)
    b = Client.load_world(b)

    a = command(a, "list", "commands.list.players")
    Client.send_packet(a, :play, "chat_command", Wire.string("say hello there"))
    {body, a} = Client.await(a, :play, "disguised_chat")
    assert :binary.match(body, "hello there") != :nomatch
    {body, b} = Client.await(b, :play, "disguised_chat")
    assert :binary.match(body, "hello there") != :nomatch

    Client.send_packet(a, :play, "chat_command", Wire.string("msg #{second} psst"))
    {_outgoing, _a} = Client.await(a, :play, "disguised_chat")
    {body, _b} = Client.await(b, :play, "disguised_chat")
    assert :binary.match(body, "psst") != :nomatch
  end
end
