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

  def spawn(_arguments, source) do
    state = source.state

    if state.life_stage == :alive do
      pose = Map.take(Valimc.World.Spawn.pose(), [:x, :y, :z])
      {1, Valimc.Player.Movement.relocate(state, Map.merge(state.player, pose))}
    else
      {0, state}
    end
  end
end
