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
    for key <- List.wrap(key), do: assert(body =~ key, "#{input}: #{inspect(body)}")
    client
  end

  defp pid(player_name),
    do: Enum.find(Valimc.Player.PlayerList.all(), &(&1.name == player_name)).pid

  defp count(pid, item) do
    id = Valimc.Protocol.ItemTypes.id(item)

    Valimc.TestConn.state(pid).inventory
    |> Valimc.Menus.Inventory.contents()
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
    assert Valimc.TestConn.state(pid).player.game_mode.current == :survival
    assert Valimc.TestConn.state(pid).inventory.infinite_materials == false

    client = command(client, "give @s minecraft:diamond 70", "commands.give.success.single")
    assert count(pid, "diamond") == 70
    client = command(client, "give @s diamond 6401", "commands.give.failed.toomanyitems")
    client = command(client, "clear @s diamond 10", "commands.clear.success.single")
    assert count(pid, "diamond") == 60
    client = command(client, "clear @s diamond 0", "commands.clear.test.single")
    _client = command(client, "clear @s minecraft:stone", "clear.failed.single")
  end

  test "item components in give and clear" do
    {client, pid} = join()

    client =
      command(
        client,
        "give @s diamond_sword[damage=5,unbreakable={}] 2",
        "commands.give.success.single"
      )

    swords =
      for %Valimc.Protocol.ItemStack{} = stack <-
            Valimc.Menus.Inventory.contents(Valimc.TestConn.state(pid).inventory),
          stack.item_id == Valimc.Protocol.ItemTypes.id("diamond_sword"),
          do: stack.components

    assert swords == [
             %{"minecraft:damage" => 5, "minecraft:unbreakable" => :unit},
             %{"minecraft:damage" => 5, "minecraft:unbreakable" => :unit}
           ]

    client = command(client, "clear @s diamond_sword[damage=4]", "clear.failed.single")

    _client =
      command(
        client,
        "clear @s diamond_sword[damage=5,unbreakable]",
        "commands.clear.success.single"
      )

    assert count(pid, "diamond_sword") == 0

    # Components the data format reads (VMC-077o): names, lore, enchantments, rarity.
    client =
      command(
        client,
        ~s(give @s iron_sword[custom_name="Blade",lore=["one",{text:"two",color:"red"}],) <>
          ~s(enchantments={"minecraft:sharpness":2},rarity="epic"]),
        # `getDisplayName` names the stack by its custom name: "Gave 1 [Blade]".
        ["commands.give.success.single", "Blade"]
      )

    [blade] =
      for %Valimc.Protocol.ItemStack{} = stack <-
            Valimc.Menus.Inventory.contents(Valimc.TestConn.state(pid).inventory),
          stack.item_id == Valimc.Protocol.ItemTypes.id("iron_sword"),
          do: stack.components

    assert blade["minecraft:custom_name"] == {:compound, %{"text" => {:string, "Blade"}}}
    assert length(blade["minecraft:lore"]) == 2
    assert blade["minecraft:enchantments"] == %{"minecraft:sharpness" => 2}
    assert blade["minecraft:rarity"] == 3

    # Item text cannot hold click events.
    _client =
      command(
        client,
        ~s(give @s stone[custom_name={text:"x",click_event:{action:"run_command",command:"/kill"}}]),
        "not supported yet"
      )
  end

  test "an operator's own experience, effects, teleport and death" do
    {client, pid} = join()

    client =
      command(client, "xp add @s 3 levels", "commands.experience.add.levels.success.single")

    assert Valimc.TestConn.state(pid).player.progression.experience.level == 3
    client = command(client, "xp set @s 100 points", "commands.experience.set.points.invalid")
    client = command(client, "xp query @s levels", "commands.experience.query.levels")

    client = command(client, "effect give @s speed 10 1", "commands.effect.give.success.single")

    assert Map.has_key?(
             Valimc.TestConn.state(pid).player.living.effects,
             Valimc.Data.EffectTypes.id("speed")
           )

    client = command(client, "effect clear @s", "commands.effect.clear.everything.success.single")
    client = command(client, "effect clear @s", "commands.effect.clear.everything.failed")

    client = command(client, "tp @s 3 70 4", "commands.teleport.success.location.single")
    assert %{x: 3.5, y: 70.0, z: 4.5} = Map.take(Valimc.TestConn.state(pid).player, [:x, :y, :z])
    client = command(client, "tp 0 30000000 0", "commands.teleport.invalidPosition")

    # As in vanilla, the death message comes before the command's feedback.
    client = command(client, "kill", "death.attack.genericKill")
    {body, _client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "commands.kill.success.single") != :nomatch
    assert Valimc.TestConn.state(pid).life_stage != :alive
  end

  test "an operator's item replace and saturation (VMC-085)" do
    {client, pid} = join()

    # `/item replace` fills the player's slots.
    client =
      command(
        client,
        "item replace entity @s weapon.mainhand with diamond_sword",
        "commands.item.entity.replace.success.single.known_item"
      )

    inventory = Valimc.TestConn.state(pid).inventory
    sword = Valimc.Protocol.ItemTypes.id("diamond_sword")
    assert %{item_id: ^sword} = inventory.slots[36 + inventory.selected]

    # Saturation lasts ticks, not seconds, and feeds each one.
    before = Valimc.TestConn.state(pid).player.food.saturation
    client = command(client, "effect give @s saturation 3", "commands.effect.give.success.single")

    Valimc.TestWait.until(fn ->
      Valimc.TestConn.state(pid).player.food.saturation == min(before + 6.0, 20.0)
    end)

    _ = client
  end

  test "every effect: Health Boost's maximum, luck, glowing and invisibility (VMC-037p)" do
    {client, pid} = join()
    living = fn -> Valimc.TestConn.state(pid).player.living end

    client =
      command(client, "effect give @s health_boost 30 1", "commands.effect.give.success.single")

    Valimc.TestWait.until(fn -> living.().health.maximum == 28.0 end)
    assert living.().health.value == 20.0

    client = command(client, "effect give @s luck 30 2", "commands.effect.give.success.single")
    assert Valimc.Living.Attributes.luck(living.().effects) == 3.0

    client =
      command(
        client,
        "effect give @s minecraft:hero_of_the_village",
        "commands.effect.give.success.single"
      )

    # Glowing and Invisibility set the shared flags; the swirls follow the effects.
    client = command(client, "effect give @s glowing 30", "commands.effect.give.success.single")

    client =
      command(
        client,
        "effect give @s invisibility 30 0 true",
        "commands.effect.give.success.single"
      )

    player = Valimc.TestConn.state(pid).player
    assert Bitwise.band(Valimc.Player.Packets.shared_flags(player), 96) == 96
    {particles, false} = Valimc.Living.Effects.particles(player.living.effects)
    # Hidden particles leave Invisibility out.
    assert length(particles) == 4

    client =
      command(
        client,
        "effect clear @s health_boost",
        "commands.effect.clear.specific.success.single"
      )

    Valimc.TestWait.until(fn -> living.().health.maximum == 20.0 end)

    _ = client
  end

  test "mobs as /effect targets (VMC-037p)" do
    {client, _pid} = join()
    # A zombie takes Speed but refuses Poison (`canBeAffected`).
    client = command(client, "summon zombie ~ ~ ~2", "commands.summon.success")

    client =
      command(
        client,
        "effect give @e[type=zombie] speed 30",
        "commands.effect.give.success.single"
      )

    client =
      command(client, "effect give @e[type=zombie] poison 30", "commands.effect.give.failed")

    _client =
      command(
        client,
        "effect clear @e[type=zombie]",
        "commands.effect.clear.everything.success.single"
      )
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
    assert Valimc.TestConn.state(pid(second)).player.game_mode.current == :adventure
  end

  test "two operators giving to each other at once both get their items" do
    {first, second} = {name("Mutual"), name("Mutual")}
    {_, a} = Client.login(first)
    on_exit(fn -> Client.close(a) end)
    {_, b} = Client.login(second)
    on_exit(fn -> Client.close(b) end)
    {a, b} = {Client.load_world(a), Client.load_world(b)}

    # Each command calls the other's connection; neither connection waits (VMC-077a).
    Client.send_packet(a, :play, "chat_command", Wire.string("give #{second} diamond 3"))
    Client.send_packet(b, :play, "chat_command", Wire.string("give #{first} emerald 2"))
    {body_a, _a} = Client.await(a, :play, "system_chat")
    {body_b, _b} = Client.await(b, :play, "system_chat")
    assert :binary.match(body_a, "commands.give.success.single") != :nomatch
    assert :binary.match(body_b, "commands.give.success.single") != :nomatch
    assert count(pid(second), "diamond") == 3
    assert count(pid(first), "emerald") == 2
  end

  test "a command whose owner does not answer fails and the session lives on" do
    {client, pid} = join()
    owner = Process.whereis(Valimc.World.Stopwatches)
    :sys.suspend(owner)
    on_exit(fn -> if Process.alive?(owner), do: :sys.resume(owner) end)
    id = "minecraft:" <> String.downcase(name("held"))
    Client.send_packet(client, :play, "chat_command", Wire.string("stopwatch create #{id}"))

    # The command waits in its job; the connection keeps answering meanwhile.
    Valimc.TestWait.until(fn ->
      Valimc.Player.Jobs.active?(Valimc.TestConn.state(pid, 1000).jobs, :command)
    end)

    # The owner call exits (5 s); before VMC-077a that exit ended the session.
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "command.failed") != :nomatch
    :sys.resume(owner)
    _client = command(client, "stopwatch remove #{id}", "commands.stopwatch")
    assert Process.alive?(pid)
  end

  test "world commands: clocks, weather, difficulty, game rules and blocks" do
    {client, _pid} = join()
    before = Valimc.World.Clock.snapshot()
    {difficulty, _} = Valimc.World.Clock.difficulty()

    on_exit(fn ->
      # `weather rain 600` below would otherwise outlive the test.
      Valimc.World.Clock.configure({:weather, :clear, 0})

      Valimc.World.Clock.configure(
        {"minecraft:overworld", :ticks, before.clocks["minecraft:overworld"].total_ticks}
      )

      Valimc.World.Clock.configure({:advance_time, before.advance_time})
      Valimc.World.Clock.configure({:difficulty, difficulty.level, true})
    end)

    # Stopped time keeps the exact tick counts below (restored on exit).
    assert :ok = Valimc.World.Clock.configure({:advance_time, false})
    client = command(client, "time set 1234", "commands.time.set.absolute")
    assert Valimc.World.Clock.snapshot().clocks["minecraft:overworld"].total_ticks == 1234
    client = await_overworld_ticks(client, 1234)
    client = command(client, "time set 1234", "commands.time.set.already_at_time")
    client = command(client, "time set noon", "commands.time.set.time_marker")
    assert Valimc.World.Clock.snapshot().clocks["minecraft:overworld"].total_ticks == 6000

    # The rain level starts rising on the next tick.
    client = command(client, "weather rain 600", "commands.weather.set.rain")
    client = await_rain(client)

    {level, id} = if difficulty.level == 3, do: {"easy", 1}, else: {"hard", 3}
    client = command(client, "difficulty #{level}", "commands.difficulty.success")
    {<<^id, _locked>>, client} = Client.await(client, :play, "change_difficulty")
    client = command(client, "difficulty #{level}", "commands.difficulty.failure")
    # Only a singleplayer owner may change difficulty from the client.
    Client.send_packet(client, :play, "change_difficulty", <<0>>)
    Client.send_packet(client, :play, "lock_difficulty", <<1>>)
    value = not Valimc.World.Clock.snapshot().advance_time
    _client = command(client, "gamerule advance_time #{value}", "commands.gamerule.set")
    assert Valimc.World.Clock.snapshot().advance_time == value
    assert %{level: ^id, locked: false} = Valimc.World.Clock.snapshot().difficulty
  end

  # Clock packets: game time, then each clock's ID, total ticks, partial tick and rate.
  defp await_overworld_ticks(client, ticks) do
    {<<_game_time::signed-64, body::binary>>, client} = Client.await(client, :play, "set_time")
    {_count, body} = Wire.take_varint(body)
    {0, body} = Wire.take_varint(body)

    case Wire.take_varint(body) do
      {^ticks, _} -> client
      _ -> await_overworld_ticks(client, ticks)
    end
  end

  defp await_rain(client) do
    case Client.await(client, :play, "game_event") do
      {<<7, level::float-32>>, client} when level > 0.0 -> client
      {_, client} -> await_rain(client)
    end
  end

  test "setblock and fill change blocks through their region owners" do
    {client, _pid} = join()
    stone = Valimc.Data.Blocks.default_state("stone")
    glass = Valimc.Data.Blocks.default_state("glass")
    client = command(client, "setblock 40 100 40 stone", "commands.setblock.success")
    assert Valimc.TestBlocks.get({40, 100, 40}) == stone
    client = command(client, "setblock 40 100 40 stone", "commands.setblock.failed")
    client = command(client, "setblock 40 100 40 glass keep", "commands.setblock.failed")
    client = command(client, "fill 40 101 40 42 103 42 glass hollow", "commands.fill.success")
    assert Valimc.TestBlocks.get({40, 101, 40}) == glass
    assert Valimc.TestBlocks.get({41, 102, 41}) == Valimc.Data.Blocks.default_state("air")

    client =
      command(client, "fill 40 101 40 42 103 42 stone replace glass", "commands.fill.success")

    assert Valimc.TestBlocks.get({42, 103, 42}) == stone
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

    # Commands with a message argument arrive as signed commands from the client.
    signed = [
      Wire.string("say signed"),
      <<0::64, 0::64>>,
      Wire.varint(0),
      Wire.varint(0),
      <<0, 0, 0, 0>>
    ]

    Client.send_packet(a, :play, "chat_command_signed", signed)
    {body, a} = Client.await(a, :play, "disguised_chat")
    assert :binary.match(body, "signed") != :nomatch
    {_, b} = Client.await(b, :play, "disguised_chat")

    Client.send_packet(a, :play, "chat_command", Wire.string("msg #{second} psst"))
    {_outgoing, _a} = Client.await(a, :play, "disguised_chat")
    {body, _b} = Client.await(b, :play, "disguised_chat")
    assert :binary.match(body, "psst") != :nomatch
  end

  test "version lines and kicking another player" do
    first = name("Admin")
    second = name("Kicked")
    {_, a} = Client.login(first)
    on_exit(fn -> Client.close(a) end)
    {_, b} = Client.login(second)
    on_exit(fn -> Client.close(b) end)
    a = Client.load_world(a)
    b = Client.load_world(b)

    a = command(a, "version", "commands.version.header")
    {lines, a} = Enum.map_reduce(1..9, a, fn _, a -> Client.await(a, :play, "system_chat") end)
    assert :binary.match(hd(lines), "commands.version.id") != :nomatch
    assert :binary.match(List.last(lines), "commands.version.stable.yes") != :nomatch

    a = command(a, "kick #{second} bye", "commands.kick.success")
    {body, _b} = Client.await(b, :play, "disconnect")
    assert :binary.match(body, "bye") != :nomatch
    _ = a
  end
end
