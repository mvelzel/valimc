defmodule Valimc.Entity.MobMotion do
  @moduledoc """
  A mob's travel state between ticks (VMC-015i), as vanilla's `LivingEntity`
  and `MoveControl` keep it: fall distance, jump delay, the slowing block's
  multiplier, the relative input and speed, the move control's operation
  and the last horizontal collision. The physics kernel runs the tick
  (`Valimc.Physics.Kernel.mobs/4`); `kernel/3` and `apply/3` convert.

  `control` is `:wait`, `{:move_to, {x, y, z}, speed}` or `{:jumping,
  speed}`: what the AI (VMC-041a) sets each tick, as navigation sets
  `MoveControl.setWantedPosition`; `jump` is its `JumpControl.jump()` for the
  tick. `water` and `lava` are the fluid heights the last move left, which
  the AI reads.
  """
  alias Valimc.Data.{EntityTypes, Float32}
  alias Valimc.Living.Attributes

  defstruct fall_distance: 0.0,
            no_jump_delay: 0,
            stuck_multiplier: {0.0, 0.0, 0.0},
            strafe: 0.0,
            forward: 0.0,
            speed: 0.0,
            control: :wait,
            horizontal_collision: false,
            jump: false,
            rise: false,
            water: 0.0,
            lava: 0.0

  @travel ~w(movement_speed jump_strength gravity step_height water_movement_efficiency
             friction_modifier air_drag_modifier)

  def valid?(%__MODULE__{} = m),
    do:
      is_float(m.fall_distance) and is_integer(m.no_jump_delay) and m.no_jump_delay in 0..10 and
        vector?(m.stuck_multiplier) and Enum.all?([m.strafe, m.forward, m.speed], &is_float/1) and
        is_boolean(m.horizontal_collision) and control?(m.control) and is_boolean(m.jump) and
        is_boolean(Map.get(m, :rise)) and
        is_float(m.water) and is_float(m.lava)

  def valid?(_), do: false

  defp control?(:wait), do: true
  defp control?({:move_to, target, speed}), do: vector?(target) and is_float(speed)
  defp control?({:jumping, speed}), do: is_float(speed)
  defp control?(_), do: false

  defp vector?({x, y, z}), do: is_float(x) and is_float(y) and is_float(z)
  defp vector?(_), do: false

  @doc """
  `MoveControl.setWantedPosition`: move toward `target` at `speed` times the
  movement speed; a jump in progress keeps jumping, at the new speed.
  """
  def move_to(%__MODULE__{control: {:jumping, _}} = motion, _target, speed),
    do: %{motion | control: {:jumping, speed * 1.0}}

  def move_to(%__MODULE__{} = motion, {x, y, z}, speed),
    do: %{motion | control: {:move_to, {x * 1.0, y * 1.0, z * 1.0}, speed * 1.0}}

  @doc """
  The kernel's map of a mob of `type` at `position` with `body` (rotation,
  velocity, ground, gravity), its `mob` (`Valimc.Entity.Mob`: travel state,
  attribute bases, effects) and whether it is alive.
  """
  def kernel(type, position, body, attributes \\ nil) do
    facts = EntityTypes.fetch(type)
    mob = body.mob
    motion = mob.motion
    effects = mob.living.effects

    alive = Valimc.Entity.Mob.alive?(mob)

    # A dying mob is immobile (`isImmobile`): it neither walks nor jumps.
    {op, target, speed} =
      case if(alive, do: motion.control, else: :wait) do
        :wait -> {:wait, nil, 0.0}
        {:move_to, target, speed} -> {:move_to, target, speed}
        {:jumping, speed} -> {:jumping, nil, speed}
      end

    attributes = attributes || travel(type, mob.attributes)

    %{
      position: position,
      yaw: body.yaw * 1.0,
      head_yaw: body.head_yaw * 1.0,
      velocity: body.velocity,
      on_ground: body.on_ground,
      horizontal_collision: motion.horizontal_collision,
      fall_distance: motion.fall_distance,
      no_jump_delay: motion.no_jump_delay,
      stuck_multiplier: motion.stuck_multiplier,
      strafe: if(alive, do: motion.strafe, else: 0.0),
      forward: if(alive, do: motion.forward, else: 0.0),
      speed: motion.speed,
      control: {op, target, speed},
      # EntityDimensions are floats.
      size:
        {Float32.round(facts.width), Float32.round(facts.height), Float32.round(facts.eye_height)},
      attributes: attributes,
      no_gravity: body.no_gravity,
      slow_falling:
        Attributes.amplifier(effects, Valimc.Data.EffectTypes.id("slow_falling")) != nil,
      levitation: Attributes.amplifier(effects, Valimc.Data.EffectTypes.id("levitation")),
      jump_boost: Attributes.jump_boost_level(effects),
      alive: alive,
      jump: alive and motion.jump,
      fall_scale: fall_scale(type),
      rise: alive and motion.rise
    }
  end

  # A blaze falls slowly (`Blaze.aiStep`).
  defp fall_scale("minecraft:blaze"), do: 0.6
  defp fall_scale(_type), do: 1.0

  @doc "The travel attributes the kernel reads of a mob of `type` with `overrides`."
  def travel(type, overrides),
    do:
      @travel
      |> Enum.map(&(Valimc.Entity.Mob.base(type, overrides, "minecraft:" <> &1) * 1.0))
      |> List.to_tuple()

  @doc """
  The body and position after a kernel tick's mob map `m`, with the fluid
  heights `{water, lava}` its move left: `{body, position}`.
  """
  def apply(body, m, {water, lava} \\ {0.0, 0.0}) do
    {op, target, speed} = m.control

    control =
      case op do
        :wait -> :wait
        :move_to -> {:move_to, target, speed}
        :jumping -> {:jumping, speed}
      end

    motion = %__MODULE__{
      fall_distance: m.fall_distance,
      no_jump_delay: m.no_jump_delay,
      stuck_multiplier: m.stuck_multiplier,
      strafe: m.strafe,
      forward: m.forward,
      speed: m.speed,
      control: control,
      horizontal_collision: m.horizontal_collision,
      water: water,
      lava: lava
    }

    body = %{
      body
      | yaw: m.yaw,
        head_yaw: m.head_yaw,
        velocity: m.velocity,
        on_ground: m.on_ground,
        mob: %{body.mob | motion: motion}
    }

    {body, m.position}
  end
end
