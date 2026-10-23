defmodule Valimc.AI.Neutral do
  @moduledoc """
  Vanilla's `NeutralMob` (VMC-043d): a mob that stays angry for a while at
  whoever it targets, and forgives. Zombified piglins use it now; endermen,
  wolves and bees share it. Its state lives in the mind's own fields
  (`Mind.own`): `anger_end`, the game time the anger ends (-1 for none), and
  `anger_target`, the reference it is angry at. A type passes its
  persistent anger range (`{min, max}` ticks, `startPersistentAngerTimer`).
  """
  alias Valimc.AI.{Self, World}

  @doc "The fields a neutral mob's own state starts with."
  def fields, do: %{anger_end: -1, anger_target: nil}

  defp own(%Self{mind: mind}), do: Map.merge(fields(), mind.own || %{})

  defp put(%Self{} = self, changes),
    do: Self.mind(self, &%{&1 | own: Map.merge(fields(), Map.merge(&1.own || %{}, changes))})

  @doc "`isAngry`: its anger ends later than now."
  def angry?(%Self{world: world} = self) do
    finish = own(self).anger_end
    finish > 0 and finish - world.time > 0
  end

  @doc "`startPersistentAngerTimer`: angry for a uniform draw of `range` ticks."
  def start_timer(%Self{} = self, {min, max}) do
    {n, self} = Self.int(self, max - min + 1)
    put(self, %{anger_end: self.world.time + min + n})
  end

  @doc "`stopBeingAngry`: no attacker, no anger, no target."
  def stop(%Self{} = self) do
    self
    |> Self.mind(&%{&1 | hurt_by: nil})
    |> put(%{anger_target: nil, anger_end: -1})
    |> Self.set_target(nil)
  end

  @doc """
  `updatePersistentAnger`: a dead mob it was angry at ends its anger;
  otherwise its target becomes what it is angry at (restarting the timer
  for a new one, or every tick with `stay`), and the anger ends when it ran
  out without a player worth staying angry at, or at a creative, spectating
  or peaceful player.
  """
  def update(%Self{} = self, stay, range) do
    previous = World.entity(self.world, self.mind.target)
    angry_at = own(self).anger_target

    if previous != nil and not previous.alive and angry_at != nil and
         angry_at == World.ref(previous) and previous.kind == :mob do
      stop(self)
    else
      target = World.target(self)

      self =
        case target do
          nil ->
            self

          target ->
            fresh = angry_at == nil or angry_at != World.ref(target)
            self = if fresh, do: put(self, %{anger_target: World.ref(target)}), else: self
            if fresh or stay, do: start_timer(self, range), else: self
        end

      self =
        if angry_at != nil and not angry?(self) and
             (target == nil or not valid_player?(self, target) or not stay),
           do: stop(self),
           else: self

      case World.entity(self.world, angry_at) do
        %{kind: :player, mode: mode} when mode in [:creative, :spectator] -> stop(self)
        %{kind: :player} when self.world.difficulty == :peaceful -> stop(self)
        _ -> self
      end
    end
  end

  # `isValidPlayerTarget`.
  defp valid_player?(%Self{world: world}, %{kind: :player, mode: mode}),
    do: mode not in [:creative, :spectator] and world.difficulty != :peaceful

  defp valid_player?(_self, _target), do: false

  @doc """
  `isAngryAt`: a target it can attack that it is angry at, or any player
  while universally angry.
  """
  def angry_at?(%Self{} = self, target) do
    World.can_attack?(self, target) and
      ((valid_player?(self, target) and angry_at_all?(self)) or
         (own(self).anger_target != nil and own(self).anger_target == World.ref(target)))
  end

  @doc "`isAngryAtAllPlayers`: universal anger, angry at no one in particular."
  def angry_at_all?(%Self{world: world} = self),
    do: world.universal_anger and angry?(self) and own(self).anger_target == nil

  @doc "`forgetCurrentTargetAndRefreshUniversalAnger`."
  def refresh(%Self{} = self, range), do: self |> stop() |> start_timer(range)
end

defmodule Valimc.AI.Goals.ResetUniversalAnger do
  @moduledoc """
  `ResetUniversalAngerTargetGoal`: under universal anger, a hurt by a
  player makes a neutral mob forget its target and be angry at every player
  (`Neutral.refresh/2`). Its kind's mobs around it do too in vanilla; that
  alert is not sent yet.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Neutral

  def new(range), do: %{range: range, last: 0}

  def can_use(state, self) do
    case self.mind.hurt_by do
      {{:player, _}, at} -> {self.world.universal_anger and at > state.last, state, self}
      _ -> {false, state, self}
    end
  end

  def start(state, self) do
    {_, at} = self.mind.hurt_by
    {%{state | last: at}, Neutral.refresh(self, state.range)}
  end
end
