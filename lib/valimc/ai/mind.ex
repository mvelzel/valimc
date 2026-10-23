defmodule Valimc.AI.Mind do
  @moduledoc """
  A mob's AI state (`Mob.ai`), as vanilla's `Mob` keeps it between ticks:
  its random, tick count and idle time, the ambient sound timer, its goal
  and target selectors, its target and aggression, the look control's
  wanted look, the body rotation control, its navigation, the jump the AI
  asked for, who last hurt it and with what, and its love and age (for
  breeding and following parents).

  Only the random is saved (`record/1`): vanilla saves no goal state, and a
  mob restored from its record starts with fresh selectors drawing on.
  """
  alias Valimc.AI.{Navigation, Random}

  defstruct random: 0,
            tick: 0,
            no_action: 0,
            ambient: 0,
            goals: {},
            targets: {},
            locked_goals: %{},
            locked_targets: %{},
            target: nil,
            aggressive: false,
            look: nil,
            body_yaw: 0.0,
            stable_head: 0.0,
            stable_time: 0,
            navigation: %Navigation{},
            jump: false,
            hurt_by: nil,
            damage: nil,
            sight: %{},
            in_love: 0,
            age: 0,
            brain: nil

  @doc "What a store saves of a mind: its random."
  def record(%__MODULE__{random: random}), do: %{random: random}

  @doc "Whether `record` is a mind's record."
  def valid?(%{random: random}), do: Random.valid?(random)
  def valid?(_record), do: false
end
