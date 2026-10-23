defmodule Valimc.AI.Kind do
  @moduledoc """
  What a mob family's module (`Valimc.AI.Mobs.*`, listed in `Valimc.AI.Mobs`)
  gives for its types: one module per mob, holding that mob's own code.
  Every callback but `types/0` and `goals/1` is optional; where a module
  leaves one out, the mob does what vanilla's `PathfinderMob` does
  (`Valimc.AI.Mobs.hook/4` dispatches).

  - `types/0`, `goals/1` (`registerGoals`), `navigation/0`
    (`createNavigation`), `brain/0`, `finalize/2` (`finalizeSpawn`,
    `Valimc.AI.Spawn`).
  - Its own data: `data/1` (defaults, saved with the body), `values/1` (the
    entity data fields a client is sent, `[{field, value, default}]`),
    `dimensions/1` (`{width, height, eye}`, nil for its type's) and `box/2`
    (its bounding box at a position, nil for the usual one).
  - How the kernel moves it (`motion/0`): `fixed` (it never moves, a
    shulker), `pushable` (others push it), `pushes` (it pushes what it
    touches), `fluid_pushed` (currents push it), `travel` (its travel, a
    squid's) and `emission` (`:all`, `:events`, `:sounds` or `:none`: what
    its movement makes); `swim_sound/0`, the sound it swims with.
  - Its tick, where vanilla's subclass overrides it, each on the mob as its
    AI sees it (`Valimc.AI.Self`): `tick_start/1` (`tick()` before
    `super.tick()`), `before_ai/1` (`aiStep()` before `super.aiStep()`),
    `custom_step/1` (`customServerAiStep`, after navigation, before the
    look control), `after_ai/1` (`aiStep()` after `super.aiStep()`, after
    the move) and `after_tick/1` (`tick()` after `super.tick()`, after the
    body rotation); `ambient_sound/1` (the sound it plays when its timer
    comes up, nil for none); `set_target/2` (`setTarget`, for a class
    that overrides it: `Self.put_target/2` stores it).
  - Its look and body controls: `look_rotations/2` (the yaw and pitch to
    turn toward, nil for none, or `:default`), `clamps_head?/0` and
    `turns_body?/0`.
  - Its own move control (`move_control/1`, after `custom_step`, before
    the look control: it sets `MobMotion`'s `set`, `impulse` and `travel`),
    and its air (`air/2`: from its air supply and whether it is in water,
    `{air, drowning damage}`; a water animal's), and how it values a
    random walk's target (`walk_value/2`, `getWalkTargetValue`). `dying?/0`:
    a dying mob still runs its own `tick` and `aiStep` hooks (a dead fish
    flops).
  - Its hurts, through `Valimc.Entity.Combat`'s one path: `ignores?/2` (a
    hit it takes nothing from), `sound/2` (its hurt or death sound, nil for
    its type's) and `hurt/2` (what a hurt leaves on its body).
  - Its fights and gear (VMC-043b): `hit/2` (what its `doHurtTarget` adds
    to a melee hit), `wants?/2` and `can_hold?/2` (an item id it picks up,
    `Valimc.AI.Pickup`), `preferred_weapons/1`, `voice/2` (the base of its
    voice pitch) and `after_move/3` (its part of the tick after the kernel
    moved it, `{body, effects}`: a zombie drowning).
  - Leads (VMC-043c3): `leashable?/0` (`canBeLeashed`; false where a family
    leaves it out, until its ticket models it).
  """
  alias Valimc.AI.Self

  @callback types() :: [String.t()]
  @callback goals(String.t()) :: {list, list}
  @callback navigation() :: {atom, keyword}
  @callback brain() :: module | nil
  @callback finalize(Self.t(), atom) :: Self.t()
  @callback data(String.t()) :: map
  @callback values(struct) :: list
  @callback dimensions(struct) :: tuple | nil
  @callback box(struct, tuple) :: tuple | nil
  @callback motion() :: keyword
  @callback tick_start(Self.t()) :: Self.t()
  @callback before_ai(Self.t()) :: Self.t()
  @callback custom_step(Self.t()) :: Self.t()
  @callback after_ai(Self.t()) :: Self.t()
  @callback after_tick(Self.t()) :: Self.t()
  @callback ambient_sound(Self.t()) :: String.t() | nil
  @callback set_target(Self.t(), term) :: Self.t()
  @callback look_rotations(Self.t(), map) :: :default | {float | nil, float | nil}
  @callback clamps_head?() :: boolean
  @callback turns_body?() :: boolean
  @callback ignores?(struct, map) :: boolean
  @callback sound(struct, String.t()) :: String.t() | nil
  @callback hurt(struct, map) :: struct
  @callback hit(Self.t(), map) :: Self.t()
  @callback wants?(Self.t(), integer) :: boolean
  @callback can_hold?(Self.t(), integer) :: boolean
  @callback preferred_weapons(String.t()) :: MapSet.t() | nil
  @callback voice(String.t(), map) :: float
  @callback after_move(struct, tuple, map) :: {struct, list}
  @callback leashable?() :: boolean
  @callback move_control(Self.t()) :: Self.t()
  @callback air(integer, boolean) :: {integer, float}
  @callback swim_sound() :: String.t()
  @callback dying?() :: boolean
  @callback walk_value(Self.t(), tuple) :: float

  @optional_callbacks leashable?: 0,
                      navigation: 0,
                      brain: 0,
                      finalize: 2,
                      data: 1,
                      values: 1,
                      dimensions: 1,
                      box: 2,
                      motion: 0,
                      tick_start: 1,
                      before_ai: 1,
                      custom_step: 1,
                      after_ai: 1,
                      after_tick: 1,
                      ambient_sound: 1,
                      set_target: 2,
                      look_rotations: 2,
                      clamps_head?: 0,
                      turns_body?: 0,
                      ignores?: 2,
                      sound: 2,
                      hurt: 2,
                      hit: 2,
                      wants?: 2,
                      can_hold?: 2,
                      preferred_weapons: 1,
                      voice: 2,
                      after_move: 3,
                      move_control: 1,
                      air: 2,
                      swim_sound: 0,
                      dying?: 0,
                      walk_value: 2
end
