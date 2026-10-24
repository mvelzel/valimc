defmodule Valimc.Entity.Dragon do
  @moduledoc """
  The dragon's body data and multipart damage rules (VMC-045a4). All eight
  parts address one living body. Its complete phase actor follows separately.
  """
  alias Valimc.AI.Dragon.{Facts, Flight}
  alias Valimc.Data.{EntityTypes, Float32}
  alias Valimc.Entity.{Body, Mob}
  alias Valimc.Living.DamageSource

  @type_name "minecraft:ender_dragon"
  @arrow_types ~w(minecraft:arrow minecraft:spectral_arrow minecraft:trident minecraft:wind_charge)
  def types, do: [@type_name]
  def goals(_type), do: {[], []}
  def data(_type), do: %{phase: 10, sitting_damage: 0.0, death_time: 0, brain: nil}
  def values(%{data: data}), do: [{:dragon_phase, data.phase, 10}]
  def volume(_body), do: 5.0
  # The dragon's 200-tick death actor awards XP in its own bursts.
  def experience(_body), do: 0
  def affected?(_effect), do: false
  def falls?, do: false

  def from_preserved(nil), do: data(@type_name)

  def from_preserved(snbt) do
    {{:compound, fields}, _} = Valimc.Text.Snbt.parse_compound(Valimc.Text.Reader.new(snbt))
    defaults = data(@type_name)
    phase = number(fields["DragonPhase"], 10)

    %{
      defaults
      | phase: if(phase in 0..10, do: phase, else: 0),
        sitting_damage: number(fields["sitting_damage_received"], 0.0) * 1.0,
        death_time: number(fields["DragonDeathTime"], 0)
    }
  rescue
    _ -> data(@type_name)
  end

  defp number({:float, <<n::float-32>>}, _default), do: n
  defp number({:double, <<n::float-64>>}, _default), do: n

  defp number({kind, n}, _default) when kind in [:byte, :short, :int, :long],
    do: n

  defp number(_, default), do: default

  @doc "The current eight part boxes, in the client's root+1 through root+8 order."
  def boxes(%Body{data: %{brain: %{flight: %Flight{} = flight}}}), do: Flight.boxes(flight)
  def boxes(_body), do: Flight.boxes(%Flight{})
  def sitting?(%{data: %{phase: phase}}), do: Facts.phase(phase).sitting
  def knockback?(body), do: not sitting?(body)

  @doc "The three podium phases reject and ignite arrows, tridents and player wind charges."
  def ignites?(%{data: %{phase: phase}}, hit),
    do: phase in [5, 6, 7] and match?(%{type: type} when type in @arrow_types, hit[:direct])

  def taken(body, hit) do
    damage = if ignites?(body, hit), do: 0.0, else: f(hit.amount)
    part = Map.get(hit, :dragon_part, 2)
    damage = if part in [0, 1], do: damage, else: f(f(damage / 4.0) + min(damage, 1.0))
    %{hit | amount: damage}
  end

  def ignores?(body, hit) do
    not admits_ignored?(body, hit) or
      not (match?(%{player: true}, hit[:attacker]) or
             DamageSource.is?(hit.source, :always_hurts_ender_dragons))
  end

  # EnderDragon.hurt admits the hit even when reallyHurt takes no health.
  def admits_ignored?(%{data: %{phase: phase}}, hit),
    do: phase != 9 and hit.amount >= f(0.01) and not part_immune?(hit)

  # The non-living part checks Entity.isInvulnerableToBase before forwarding
  # to the root. A direct root hit instead admits an immune reallyHurt.
  defp part_immune?(%{dragon_part: _, source: source}),
    do:
      (DamageSource.is?(source, :is_fire) and EntityTypes.fetch(@type_name).fire_immune) or
        (DamageSource.is?(source, :is_fall) and EntityTypes.tag?(@type_name, "fall_damage_immune"))

  defp part_immune?(_hit), do: false

  @doc "Subclass killing-blow and sitting-damage rules before shared hurt events."
  def damage_result(body, mob, outcome) do
    if sitting?(body) do
      received =
        f(f(body.data.sitting_damage + body.mob.living.health.value) - mob.living.health.value)

      data =
        if received > f(0.25 * mob.living.health.maximum),
          do: %{body.data | sitting_damage: 0.0, phase: 4},
          else: %{body.data | sitting_damage: received}

      {%{body | data: data}, mob, outcome}
    else
      if outcome.died do
        health = %{mob.living.health | value: 1.0, death_ticks: 0}
        mob = %{mob | living: %{mob.living | health: health}}
        {%{body | data: %{body.data | phase: 9}}, mob, %{outcome | died: false}}
      else
        {body, mob, outcome}
      end
    end
  end

  @doc "Native timers without an ordinary mob's twenty-tick removal or death poof."
  def timers(body) do
    {mob, _} = Mob.tick(body.mob)
    {%{body | mob: mob}, [], false}
  end

  defp f(value), do: Float32.round(value)
end
