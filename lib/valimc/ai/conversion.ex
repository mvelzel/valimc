defmodule Valimc.AI.Conversion do
  @moduledoc """
  `Mob.convertTo` with `ConversionParams.single(keepEquipment,
  preserveCanPickUpLoot)` (VMC-043b): the mob a converting body becomes, a
  fresh one of its new type with a new uuid that keeps its rotation,
  motion, equipment and drop chances, effects, absorption, hurt time, the
  player that hurt it, baby flag, loot pickup, handedness, persistence and
  name; then its new kind's step after a conversion (a zombie's
  attributes).
  """
  alias Valimc.AI.{Mobs, Self}
  alias Valimc.Entity.Body

  @doc "The body `body` becomes as type `to` with `uuid`, at the `special` multiplier."
  def convert(%Body{} = body, uuid, to, special) do
    {:ok, new} = Body.new(to)
    mob = body.mob
    living = mob.living

    fresh = %{
      new.mob
      | equipment: mob.equipment,
        drop_chances: mob.drop_chances,
        motion: %{new.mob.motion | fall_distance: mob.motion.fall_distance},
        player_memory: mob.player_memory,
        hurt_by_player: mob.hurt_by_player,
        living: %{
          new.mob.living
          | effects: living.effects,
            absorption: living.absorption,
            health: %{new.mob.living.health | hurt_ticks: living.health.hurt_ticks}
        },
        can_pick_up_loot: mob.can_pick_up_loot,
        left_handed: mob.left_handed,
        no_ai: mob.no_ai,
        persistent: mob.persistent,
        ai: Valimc.AI.mind(to, uuid, nil)
    }

    new = %{
      new
      | yaw: body.yaw,
        pitch: body.pitch,
        head_yaw: body.head_yaw,
        velocity: body.velocity,
        on_ground: body.on_ground,
        no_gravity: body.no_gravity,
        custom_name: body.custom_name,
        portal_cooldown: body.portal_cooldown,
        mob: fresh
    }

    # `convertCommon`: a baby stays a baby.
    new =
      if Mobs.hook(body.type, :baby?, [body], false) do
        self = %Self{type: to, mob: new.mob, mind: new.mob.ai, data: new.data}
        self = Mobs.hook(to, :set_baby, [self, true], self)
        %{new | data: self.data, mob: self.mob}
      else
        new
      end

    Mobs.hook(to, :after_conversion, [new, uuid, special], new)
  end
end
