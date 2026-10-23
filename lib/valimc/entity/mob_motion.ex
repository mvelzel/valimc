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
  tick. `water` and `lava` are the fluid heights the last move left, and
  `powder_snow` whether it ended inside powder snow, which the AI reads. A
  rabbit's `hop` (VMC-043c) keeps its hopping controls: whether it is
  jumping, its wanted position and speeds (`RabbitMoveControl`).
  """
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
            lava: 0.0,
            powder_snow: false,
            hop: nil

  @travel ~w(movement_speed jump_strength gravity step_height water_movement_efficiency
             friction_modifier air_drag_modifier)

  def valid?(%__MODULE__{} = m),
    do:
      is_float(m.fall_distance) and is_integer(m.no_jump_delay) and m.no_jump_delay in 0..10 and
        vector?(m.stuck_multiplier) and Enum.all?([m.strafe, m.forward, m.speed], &is_float/1) and
        is_boolean(m.horizontal_collision) and control?(m.control) and is_boolean(m.jump) and
        is_boolean(Map.get(m, :rise)) and
        is_float(m.water) and is_float(m.lava) and is_boolean(m.powder_snow) and hop?(m.hop)

  def valid?(_), do: false

  defp hop?(nil), do: true

  defp hop?(%{jumping: jumping, wanted: wanted, speed: speed, next_speed: next}),
    do:
      is_boolean(jumping) and (wanted == nil or vector?(wanted)) and is_float(speed) and
        is_float(next)

  defp hop?(_), do: false

  @doc "A rabbit's controls before its first move (`hop`)."
  def hop, do: %{jumping: false, wanted: {0.0, 0.0, 0.0}, speed: 0.0, next_speed: 0.0}

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
  def move_to(%__MODULE__{hop: %{} = hop} = motion, {x, y, z}, speed) do
    # `RabbitMoveControl.setWantedPosition`: in water at 1.5, its next hop's
    # speed kept.
    speed = if motion.water > 0.0, do: 1.5, else: speed * 1.0
    target = {x * 1.0, y * 1.0, z * 1.0}
    hop = %{hop | wanted: target, speed: speed}
    hop = if speed > 0.0, do: %{hop | next_speed: speed}, else: hop
    move_to(%{motion | hop: nil}, target, speed) |> Map.put(:hop, hop)
  end

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
      # EntityDimensions are floats (a baby's its own, VMC-043b).
      size: Valimc.Entity.Body.dimensions(body),
      attributes: attributes,
      no_gravity: body.no_gravity,
      slow_falling:
        Attributes.amplifier(effects, Valimc.Data.EffectTypes.id("slow_falling")) != nil,
      levitation: Attributes.amplifier(effects, Valimc.Data.EffectTypes.id("levitation")),
      jump_boost: Attributes.jump_boost_level(effects),
      alive: alive,
      jump: alive and motion.jump,
      fall_scale: fall_scale(type),
      rise: alive and motion.rise,
      powder_snow_walkable: powder_snow_walkable?(type, mob),
      was_powder_snow: motion.powder_snow,
      hop: hop(motion.hop, position, body)
    }
    |> Map.merge(kind_motion(type))
    # A `NoAI` mob does not travel (`isEffectiveAi`).
    |> then(&if(mob.no_ai, do: %{&1 | fixed: true}, else: &1))
  end

  @walkable MapSet.new(
              Valimc.Protocol.Data.tags()["minecraft:entity_type"][
                "minecraft:powder_snow_walkable_mobs"
              ]
            )
  @leather_boots Valimc.Protocol.ItemTypes.id("minecraft:leather_boots")

  # `PowderSnowBlock.canEntityWalkOnPowderSnow`.
  defp powder_snow_walkable?(type, mob),
    do:
      MapSet.member?(@walkable, Valimc.Data.EntityTypes.id(type)) or
        match?(%{feet: %{item_id: @leather_boots}}, mob.equipment)

  @default_kind %{fixed: false, pushable: true, pushes: true}

  # How a family's mob moves and pushes (`Valimc.AI.Kind.motion/0`).
  defp kind_motion(type),
    do: Map.merge(@default_kind, Map.new(Valimc.AI.Mobs.hook(type, :motion, [], [])))

  # A blaze falls slowly (`Blaze.aiStep`).
  defp fall_scale("minecraft:blaze"), do: 0.6
  defp fall_scale(_type), do: 1.0

  defp hop(nil, _position, _body), do: nil

  defp hop(hop, position, body) do
    %{
      jumping: hop.jumping,
      wanted: hop.wanted || position,
      speed: hop.speed,
      next_speed: hop.next_speed,
      path_up: Map.get(hop, :path_up, false),
      baby: Valimc.Entity.Animal.baby?(body),
      started: false,
      jumped: false,
      nav_speed: nil
    }
  end

  @doc """
  The travel attributes the kernel reads of a mob of `type` with `overrides`
  (their bases and modifiers: a zombified piglin's attacking speed, a
  baby's speed).
  """
  def travel(type, overrides),
    do:
      @travel
      |> Enum.map(fn name ->
        name = "minecraft:" <> name
        base = Valimc.Entity.Mob.base(type, overrides, name)
        Attributes.value(name, base, get_in(overrides, [name, :modifiers]) || []) * 1.0
      end)
      |> List.to_tuple()

  @doc """
  The body and position after a kernel tick's mob map `m`, with the fluid
  heights `{water, lava}` its move left and whether it ended in powder
  snow: `{body, position}`.
  """
  def apply(body, m, {water, lava} \\ {0.0, 0.0}, powder_snow \\ false) do
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
      lava: lava,
      powder_snow: powder_snow,
      # What the hop did this tick (`started`, `jumped`, `nav_speed`) stays
      # until the rabbit's AI settles it.
      hop: m.hop && Map.drop(m.hop, [:path_up, :baby])
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
