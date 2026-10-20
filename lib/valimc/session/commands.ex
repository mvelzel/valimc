defmodule Valimc.Session.Commands do
  @moduledoc "Chat throttling and the server's chat commands (VMC-069)."

  alias Valimc.Protocol.{
    Packets
  }

  alias Valimc.Player.Movement

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{
    ChatThrottle,
    Metrics
  }

  alias Valimc.World.{}

  def throttle_chat(state) do
    case ChatThrottle.record(state.chat_throttle) do
      {:ok, throttle} -> %{state | chat_throttle: throttle}
      {:spam, _} -> reject(state, "Kicked for spamming")
    end
  end

  def command(state, input), do: execute_command(state, Valimc.Commands.resolve(input))

  def execute_command(state, :help) do
    send_packets(state, [
      Packets.chat(Valimc.Commands.help_text())
    ])

    state
  end

  def execute_command(state, :stats) do
    stats = Metrics.snapshot()

    send_packets(state, [
      Packets.chat(
        "#{stats.players} players · #{stats.regions} regions · #{stats.schedulers} schedulers · #{div(stats.memory_bytes, 1_048_576)} MiB"
      )
    ])

    state
  end

  def execute_command(state, :spawn) do
    if state.life_stage == :alive,
      do: Movement.relocate(state, %{state.player | x: 0.5, y: 64.0, z: 0.5}),
      else: state
  end

  def execute_command(state, :unknown) do
    send_packets(state, [Packets.chat("Unknown command. Use /help.")])
    state
  end
end
