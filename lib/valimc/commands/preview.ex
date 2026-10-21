defmodule Valimc.Commands.Preview do
  @moduledoc "ValiMC's own commands beside vanilla's: `/stats` and `/spawn` (VMC-002)."
  alias Valimc.Command.{Feedback, Text}

  def stats(_arguments, source) do
    stats = Valimc.Metrics.snapshot()

    Feedback.success(
      source,
      Text.literal(
        "#{stats.players} players · #{stats.regions} regions · #{stats.schedulers} schedulers · #{div(stats.memory_bytes, 1_048_576)} MiB"
      ),
      false
    )

    {1, source.state}
  end

  # The world spawn is the overworld's; from another dimension the player travels there.
  def spawn(_arguments, source) do
    state = source.state

    if state.life_stage == :alive do
      pose =
        Valimc.World.Spawn.pose()
        |> Map.take([:x, :y, :z])
        |> Map.merge(%{yaw: state.player.yaw, pitch: state.player.pitch, dimension: :overworld})

      {1, Valimc.Player.Teleports.apply(state, pose)}
    else
      {0, state}
    end
  end
end
