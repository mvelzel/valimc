defmodule Valimc.AI.Mind do
  @moduledoc """
  A mob's AI state (`Mob.ai`), as vanilla's `Mob` keeps it between ticks:
  its random, tick count and idle time, the ambient sound timer, its goal
  and target selectors, its target and aggression, the look control's
  wanted look, the body rotation control, its navigation, the jump (and a
  blaze's lift) the AI asked for, who last hurt it and with what, the
  gaussian its random holds back, an animal's particle timers, and `own`:
  what its type keeps beyond these (a family's fields, e.g. a blaze's height
  offset, a rabbit's hops). An animal's age and love are its body's data
  (VMC-043c).

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
            rise: false,
            hurt_by: nil,
            damage: nil,
            sight: %{},
            brain: nil,
            # The second of a pair of gaussian draws (`MarsagliaPolarGaussian`).
            gaussian: nil,
            # An animal's particle timers (`forcedAgeTimer`, `ageLockParticleTimer`).
            forced_age_timer: 0,
            age_lock_timer: 0,
            own: nil

  @doc "What a store saves of a mind: its random."
  def record(%__MODULE__{random: random}), do: %{random: random}

  @doc "Whether `record` is a mind's record."
  def valid?(%{random: random}), do: Random.valid?(random)
  def valid?(_record), do: false
end
