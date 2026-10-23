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
    shulker), `pushable` (others push it) and `pushes` (it pushes what it
    touches).
  - Its tick, where vanilla's subclass overrides it, each on the mob as its
    AI sees it (`Valimc.AI.Self`): `tick_start/1` (`tick()` before
    `super.tick()`), `before_ai/1` (`aiStep()` before `super.aiStep()`),
    `custom_step/1` (`customServerAiStep`, after navigation, before the
    look control), `after_ai/1` (`aiStep()` after `super.aiStep()`, after
    the move) and `after_tick/1` (`tick()` after `super.tick()`, after the
    body rotation); `ambient_sound/1` (the sound it plays when its timer
    comes up, nil for none).
  - Its look and body controls: `look_rotations/2` (the yaw and pitch to
    turn toward, nil for none, or `:default`), `clamps_head?/0` and
    `turns_body?/0`.
  - Its hurts, through `Valimc.Entity.Combat`'s one path: `ignores?/2` (a
    hit it takes nothing from), `sound/2` (its hurt or death sound, nil for
    its type's) and `hurt/2` (what a hurt leaves on its body).
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
  @callback look_rotations(Self.t(), map) :: :default | {float | nil, float | nil}
  @callback clamps_head?() :: boolean
  @callback turns_body?() :: boolean
  @callback ignores?(struct, map) :: boolean
  @callback sound(struct, String.t()) :: String.t() | nil
  @callback hurt(struct, map) :: struct

  @optional_callbacks navigation: 0,
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
                      look_rotations: 2,
                      clamps_head?: 0,
                      turns_body?: 0,
                      ignores?: 2,
                      sound: 2,
                      hurt: 2
end
