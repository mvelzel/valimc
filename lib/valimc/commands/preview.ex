defmodule Valimc.Commands.Preview do
  @moduledoc "ValiMC's own commands beside vanilla's: `/stats` and `/spawn` (VMC-002)."
  alias Valimc.Command.{Feedback, Source, Text}
  alias Valimc.Commands.Remote

  def stats(_arguments, source) do
    stats = Valimc.Metrics.snapshot()

    Feedback.success(
      source,
      Text.literal(
        "#{stats.players} players · #{stats.regions} regions · #{stats.schedulers} schedulers · #{div(stats.memory_bytes, 1_048_576)} MiB"
      ),
      false
    )

    1
  end

  # The world spawn, in its dimension; from another dimension the player travels there.
  def spawn(_arguments, source) do
    player = Source.player!(source)

    pose =
      Valimc.World.Spawn.pose()
      |> Map.take([:x, :y, :z])
      |> Map.merge(%{
        yaw: player.yaw,
        pitch: player.pitch,
        dimension: Valimc.World.Spawn.dimension()
      })

    # Dead players stay where they are.
    if player.health.value > 0 and Remote.run!(player, {:teleport, pose}) == :ok, do: 1, else: 0
  end
end
