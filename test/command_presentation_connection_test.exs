defmodule Valimc.CommandPresentationConnectionTest do
  use ExUnit.Case, async: false
  # Presentation, area and server commands over sockets (VMC-053i/j).
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.Wire

  defp name(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  defp send_command(client, input),
    do: Client.send_packet(client, :play, "chat_command", Wire.string(input))

  defp command(client, input, key) do
    send_command(client, input)
    feedback(client, input, key)
  end

  defp feedback(client, input, key) do
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, key) != :nomatch, "#{input}: #{inspect(body)}"
    client
  end

  defp join do
    player = name("Show")
    {_, client} = Client.login(player)
    on_exit(fn -> Client.close(client) end)
    Client.load_world(client)
  end

  test "tellraw, title, particle, playsound and posteffect reach the player" do
    client = join()

    send_command(client, ~s(tellraw @s {text:"raw",bold:true}))
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "raw") != :nomatch

    send_command(client, ~s(title @s title "Big"))
    {body, client} = Client.await(client, :play, "set_title_text")
    assert :binary.match(body, "Big") != :nomatch
    client = feedback(client, "title", "commands.title.show.title.single")
    client = command(client, "title @s times 1 2 3", "commands.title.times.single")

    send_command(client, "particle flame ~ ~1 ~ 0 0 0 0 5")
    {_body, client} = Client.await(client, :play, "level_particles")
    client = feedback(client, "particle", "commands.particle.success")

    send_command(client, "playsound minecraft:entity.pig.ambient master @s")
    {body, client} = Client.await(client, :play, "sound")
    assert :binary.match(body, "entity.pig.ambient") != :nomatch
    client = feedback(client, "playsound", "commands.playsound.success.single")

    send_command(client, "posteffect add @s minecraft:invert")
    {body, client} = Client.await(client, :play, "post_effects")
    assert :binary.match(body, "minecraft:invert") != :nomatch
    client = feedback(client, "posteffect", "commands.posteffect.add.success.single")

    _client =
      command(client, "posteffect add @s minecraft:invert", "commands.posteffect.add.failed")
  end

  test "clone copies blocks within the overworld" do
    client = join()
    stone = Valimc.Data.Blocks.default_state("stone")
    glass = Valimc.Data.Blocks.default_state("glass")
    air = Valimc.Data.Blocks.default_state("air")
    client = command(client, "fill 60 100 60 61 101 61 stone", "commands.fill.success")
    client = command(client, "setblock 60 100 60 glass", "commands.setblock.success")
    client = command(client, "clone 60 100 60 61 101 61 70 100 70", "commands.clone.success")
    assert Valimc.TestBlocks.get({70, 100, 70}) == glass
    assert Valimc.TestBlocks.get({71, 101, 71}) == stone
    client = command(client, "clone 60 100 60 61 101 61 61 100 60", "commands.clone.overlap")

    client =
      command(
        client,
        "clone 60 100 60 61 101 61 80 100 80 filtered glass move",
        "commands.clone.success"
      )

    assert Valimc.TestBlocks.get({80, 100, 80}) == glass
    assert Valimc.TestBlocks.get({60, 100, 60}) == air
    assert Valimc.TestBlocks.get({81, 100, 80}) == air
    _client = command(client, "clone 0 0 0 40 40 40 50 50 50", "commands.clone.toobig")
  end

  test "forceload keeps a set of chunks" do
    client = join()
    client = command(client, "forceload add 320 320", "commands.forceload.added.single")
    client = command(client, "forceload add 320 320", "commands.forceload.added.failure")
    client = command(client, "forceload query 330 330", "commands.forceload.query.success")
    client = command(client, "forceload query", "[20, 20]")
    client = command(client, "forceload add 0 0 1000 1000", "commands.forceload.toobig")
    _client = command(client, "forceload remove 320 320", "commands.forceload.removed.single")
  end

  test "stopwatches and the frozen tick rate" do
    client = join()
    id = "minecraft:" <> String.downcase(name("race"))
    on_exit(fn -> Valimc.World.TickRate.unfreeze() end)

    client = command(client, "stopwatch create #{id}", "commands.stopwatch.create.success")
    client = command(client, "stopwatch create #{id}", "commands.stopwatch.already_exists")
    client = command(client, "stopwatch query #{id}", "commands.stopwatch.query")
    client = command(client, "stopwatch remove #{id}", "commands.stopwatch.remove.success")

    # As in vanilla, the tick state reaches players before the command's feedback.
    client = command(client, "tick step", "commands.tick.step.fail")
    Client.send_packet(client, :play, "chat_command", Wire.string("tick freeze"))
    {<<_rate::float-32, frozen>>, client} = Client.await(client, :play, "ticking_state")
    assert frozen == 1
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "commands.tick.status.frozen") != :nomatch
    Client.send_packet(client, :play, "chat_command", Wire.string("tick step 5"))
    {_steps, client} = Client.await(client, :play, "ticking_step")
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "commands.tick.step.success") != :nomatch
    Client.send_packet(client, :play, "chat_command", Wire.string("tick unfreeze"))
    {<<_rate::float-32, frozen>>, client} = Client.await(client, :play, "ticking_state")
    assert frozen == 0
    {body, _client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "commands.tick.status.running") != :nomatch
  end
end
