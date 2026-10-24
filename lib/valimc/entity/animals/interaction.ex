defmodule Valimc.Entity.Animals.Interaction do
  @moduledoc """
  A player's use of an item on an animal (VMC-043c), vanilla's
  `Mob.interact` past the name tag: the animal's own `mobInteract` (milking,
  shearing, a mooshroom's stew and flowers), then `Animal.mobInteract`
  (food: love for an adult, a tenth of its time for a baby), `AgeableMob`'s
  golden dandelion, then the item's own `interactLivingEntity` (dye on a
  sheep).

  `request` is `%{item: stack | nil, infinite: boolean}` (whether the
  player has infinite materials). The answer is `:pass`, `:consume` (the use
  is taken, nothing happens: shears on a sheep not ready) or `{:ok, body,
  outcome}`: `outcome` holds `hand` (`:keep`, `{:use, n}`, `{:fill, stack}`
  or `{:wear, n}`; bucket capture uses `{:capture, stack}`), `swing` (the server swings the player's arm,
  `SUCCESS_SERVER`), `events` (the animal's: sounds to everyone, entity
  events), `others` (a sound the player itself made, to the others, at the
  animal), `drops` (`[{stack, {x, y, z} offset from the animal, velocity}]`)
  `discard` (a captured animal is removed without death drops), `convert` (the body it becomes, a new entity: a sheared mooshroom's
  cow) and `free` (the fence knots a lead it dropped was tied to,
  `Valimc.Entity.Leashes`). Draws on the animal's own random use its mind's.
  """
  import Bitwise
  alias Valimc.AI.{Mind, Random}
  alias Valimc.Data.{EntityTypes, Float32}
  alias Valimc.Entity.{Animal, Body}
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @golden_dandelion ItemTypes.id("minecraft:golden_dandelion")

  @doc "What using `request.item` on animal `body` does (see the module doc)."
  def interact(%Body{type: type, mob: mob} = body, request) do
    cond do
      not Animal.animal?(type) or not Valimc.Entity.Mob.alive?(mob) -> :pass
      true -> chain(body, request)
    end
  end

  defp chain(body, request) do
    module = Animal.module(body.type)

    own =
      if function_exported?(module, :interact, 2),
        do: apply(module, :interact, [body, request]),
        else: :pass

    with :pass <- own,
         :pass <- feed(body, request),
         :pass <- dandelion(body, request) do
      if function_exported?(module, :use_item, 2),
        do: apply(module, :use_item, [body, request]),
        else: :pass
    end
  end

  @doc "An outcome with these fields (the rest none)."
  def outcome(fields),
    do:
      Map.merge(
        %{
          hand: :keep,
          swing: false,
          events: [],
          others: nil,
          drops: [],
          convert: nil,
          discard: false,
          free: []
        },
        Map.new(fields)
      )

  # `Animal.mobInteract`: food makes an adult fall in love (an adult past
  # breeding, or one in love, ignores it) or ages a baby on.
  defp feed(%Body{type: type, data: data} = body, %{item: %ItemStack{item_id: id}} = request) do
    cond do
      not Animal.food?(type, id) ->
        :pass

      data.age == 0 and Animal.can_fall_in_love?(type, data) ->
        {body, events} = Animal.fall_in_love(body, Map.get(request, :player))
        {body, eat} = eating_sound(body)
        {:ok, body, outcome(hand: fed(id), swing: true, events: events ++ eat)}

      Animal.can_age_up?(data) ->
        body = Animal.feed_baby(body)
        {body, eat} = eating_sound(body)
        {:ok, body, outcome(hand: fed(id), events: eat)}

      true ->
        :pass
    end
  end

  defp feed(_body, _request), do: :pass

  @tropical_fish_bucket ItemTypes.id("minecraft:tropical_fish_bucket")

  # `usePlayerItem`: an axolotl's bucket of fish leaves a water bucket
  # (`Axolotl.usePlayerItem`, VMC-043e), other food is used up.
  defp fed(@tropical_fish_bucket),
    do: {:fill, ItemStack.new("minecraft:water_bucket")}

  defp fed(_id), do: {:use, 1}

  # `playEatingSound`: a pig's (its sound variant's, at its voice pitch).
  defp eating_sound(%Body{type: "minecraft:pig", data: data} = body) do
    name = Animal.sound_set("pig", data)["eat"]
    {pitch, body} = draw(body, &Random.voice_pitch(&1, data.age < 0))
    volume = Valimc.AI.Facts.mob("minecraft:pig").volume
    {body, [sound(Animal.sound_id(name), "neutral", volume, pitch)]}
  end

  defp eating_sound(body), do: {body, []}

  # `AgeableMob.mobInteract`: a golden dandelion locks a baby's age (or
  # unlocks it), back to a newborn's, unless its type cannot be locked or it
  # was just used.
  defp dandelion(%Body{type: type, data: data, mob: mob} = body, %{
         item: %ItemStack{item_id: @golden_dandelion}
       }) do
    timer = if match?(%Mind{}, mob.ai), do: mob.ai.age_lock_timer, else: 0

    if data.age < 0 and timer == 0 and not EntityTypes.tag?(type, "cannot_be_age_locked") do
      locked = not data.age_locked
      data = %{data | age_locked: locked, age: -24_000}
      mob = if locked, do: %{mob | persistent: true}, else: mob
      mob = if match?(%Mind{}, mob.ai), do: %{mob | ai: %{mob.ai | age_lock_timer: 40}}, else: mob

      name =
        if locked,
          do: "minecraft:item.golden_dandelion.use",
          else: "minecraft:item.golden_dandelion.unuse"

      {:ok, %{body | data: data, mob: mob},
       outcome(
         hand: {:use, 1},
         events: [sound(Animal.sound_id(name), "player", 1.0, 1.0, :block)]
       )}
    else
      :pass
    end
  end

  defp dandelion(_body, _request), do: :pass

  @doc "A sound event at the animal (`at: :block` plays at its block's centre)."
  def sound(id, source, volume, pitch, at \\ :entity) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

    if at == :block,
      do: {:sound_block, id, source, volume, pitch, seed},
      else: {:sound, id, source, volume, pitch, seed}
  end

  @doc "A draw from the animal's own random (its mind's): `{value, body}`."
  def draw(%Body{mob: %{ai: %Mind{random: random} = mind} = mob} = body, fun) do
    {value, random} = fun.(random)
    {value, %{body | mob: %{mob | ai: %{mind | random: random}}}}
  end

  def draw(%Body{mob: %{ai: %{random: random}} = mob} = body, fun) do
    {value, random} = fun.(random)
    {value, %{body | mob: %{mob | ai: %{random: random}}}}
  end

  def draw(%Body{mob: mob} = body, fun) do
    draw(%{body | mob: %{mob | ai: %{random: Random.new(:rand.uniform(1 <<< 47))}}}, fun)
  end

  @doc "`(nextFloat() - nextFloat()) * scale` of the animal's random, in floats."
  def spread(body, scale) do
    {a, body} = draw(body, &Random.float/1)
    {b, body} = draw(body, &Random.float/1)
    {Float32.round(Float32.round(a - b) * Float32.round(scale)), body}
  end
end
