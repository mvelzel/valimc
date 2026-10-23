defmodule Valimc.AI.Mobs.Endermite do
  @moduledoc """
  `Endermite`: a small melee monster that walks on powder snow. Its body
  always faces its yaw (`tick` sets `yBodyRot` first), and one that is not
  persistent lives 2400 ticks (`Lifetime`, saved), then is discarded.
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Self}

  @life 2400

  @impl true
  def types, do: ["minecraft:endermite"]

  @impl true
  def goals(_type) do
    {[
       {1, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "ClimbOnTopOfPowderSnowGoal", Goals.ClimbPowderSnow, [:jump], %{}},
       {2, "MeleeAttackGoal", Goals.MeleeAttack, [:move, :look],
        Goals.MeleeAttack.new(1.0, false)},
       {3, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)},
       {7, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(alert: true, alert_types: ["minecraft:endermite"])},
       {2, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true)}
     ]}
  end

  @impl true
  def data(_type), do: %{life: 0}

  @impl true
  def motion, do: [emission: :events]

  @impl true
  def tick_start(self), do: Self.mind(self, &%{&1 | body_yaw: self.yaw})

  @impl true
  def after_ai(%Self{data: data} = self) do
    life = if self.mob.persistent, do: data.life, else: data.life + 1
    self = %{self | data: %{data | life: life}}
    if life >= @life, do: Self.effect(self, :discard), else: self
  end
end
