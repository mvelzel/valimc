defmodule Valimc.Entity.Bucketable do
  @moduledoc """
  Fish and axolotl bucket data (VMC-043e8), as `Bucketable` and the families'
  save/load methods. Pure body/item changes; the owning group removes or
  releases the body with the player's held stack in its existing callback.
  """
  import Bitwise
  alias Valimc.AI.{Mind, Random, Self}
  alias Valimc.Entity.{Body, Leashes, Mob}
  alias Valimc.Entity.Animals.Interaction
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @types Valimc.Data.BucketFacts.types()
  @items Map.new(@types, fn {type, row} -> {ItemTypes.id(row["item"]), type} end)
  @water ItemTypes.id("water_bucket")

  def type(item), do: @items[item]

  @doc "`EntityType.getYOffset`: the constructor-sized body descends at most one block."
  def spawn_point(type, {x, y, z}, read) do
    {:ok, initial} = Body.new(type)
    {width, _height, _eye} = Body.dimensions(initial)
    half = width / 2
    bottom = y + 1.0

    cells =
      for bx <- (x - 1)..(x + 1), by <- (y - 1)..(y + 1), bz <- (z - 1)..(z + 1), do: {bx, by, bz}

    Enum.reduce_while(cells, {:ok, y * 1.0}, fn {bx, by, bz} = cell, {:ok, floor} ->
      case read.(cell) do
        nil ->
          {:halt, {:error, :unloaded_bucket_position}}

        state ->
          {shape, {ox, oy, oz}} = Valimc.Physics.Clip.collider(state, cell)

          floor =
            Enum.reduce(shape.boxes, floor, fn {x0, y0, z0, x1, y1, z1}, floor ->
              {x0, y0, z0, x1, y1, z1} =
                {x0 + bx + ox, y0 + by + oy, z0 + bz + oz, x1 + bx + ox, y1 + by + oy,
                 z1 + bz + oz}

              # The native query is the target block's box; collision clips
              # the mob's horizontal footprint with the usual shape epsilon.
              if x1 > x and x0 < x + 1 and y1 > y and y0 < y + 1 and
                   z1 > z and z0 < z + 1 and x1 > x + 0.5 - half + 1.0e-7 and
                   x0 < x + 0.5 + half - 1.0e-7 and z1 > z + 0.5 - half + 1.0e-7 and
                   z0 < z + 0.5 + half - 1.0e-7 and y1 <= bottom + 1.0e-7,
                 do: max(floor, y1),
                 else: floor
            end)

          {:cont, {:ok, floor}}
      end
    end)
    |> case do
      {:ok, floor} -> {:ok, {x + 0.5, floor, z + 0.5}}
      error -> error
    end
  end

  @doc "`bucketMobPickup`: only a live bucketable and a water bucket."
  def interact(%Body{type: type, mob: %Mob{} = mob} = body, %{
        item: %ItemStack{item_id: @water}
      }) do
    if Map.has_key?(@types, type) and Mob.alive?(mob) do
      stack = capture(body)
      {body, drops, free} = if mob.leash, do: Leashes.drop(body), else: {body, [], []}
      sound = @types[type]["pickup_sound"]

      {:ok, body,
       Interaction.outcome(
         hand: {:capture, stack},
         discard: true,
         events: [Interaction.sound(sound, "neutral", 1.0, 1.0)],
         drops: drops,
         free: free
       )}
    else
      :pass
    end
  end

  def interact(_body, _request), do: :pass

  @doc "Whether a bucket of water takes mobs of `type`."
  def bucketable?(type), do: Map.has_key?(@types, type)

  @doc "The bucket item, its name/variant components and modelled entity data."
  def capture(%Body{type: type, mob: mob} = body) when is_map_key(@types, type) do
    data = %{"Health" => {:float, <<mob.living.health.value::float-32>>}}

    data =
      Enum.reduce(
        [
          {"NoAI", mob.no_ai},
          {"NoGravity", body.no_gravity},
          {"PersistenceRequired", mob.persistent}
        ],
        data,
        fn {name, value}, data -> if value, do: Map.put(data, name, {:byte, 1}), else: data end
      )

    data =
      if type == "minecraft:axolotl" do
        data
        |> Map.put("Age", {:int, body.data.age})
        |> Map.put("AgeLocked", {:byte, if(body.data.age_locked, do: 1, else: 0)})
        |> cooldown(mob.ai)
      else
        data
      end

    components =
      variants(body)
      |> Map.put("minecraft:bucket_entity_data", {:compound, data})

    components =
      if body.custom_name,
        do: Map.put(components, "minecraft:custom_name", body.custom_name),
        else: components

    %{ItemStack.new(@types[type]["item"]) | components: components}
  end

  defp cooldown(data, %Mind{brain: %{memories: memories}}),
    do: cooldown(data, %{memories: memories})

  defp cooldown(data, %{memories: %{has_hunting_cooldown: {_, ttl}}}) when is_integer(ttl),
    do: Map.put(data, "HuntingCooldown", {:long, ttl})

  defp cooldown(data, _), do: data

  defp variants(%{type: "minecraft:salmon", data: data}),
    do: %{"minecraft:salmon/size" => data.size}

  defp variants(%{type: "minecraft:axolotl", data: data}),
    do: %{"minecraft:axolotl/variant" => data.variant}

  defp variants(%{type: "minecraft:tropical_fish", data: %{variant: packed}}),
    do: %{
      "minecraft:tropical_fish/pattern" => band(packed, 0xFFFF),
      "minecraft:tropical_fish/base_color" => band(packed >>> 16, 255),
      "minecraft:tropical_fish/pattern_color" => band(packed >>> 24, 255)
    }

  defp variants(_body), do: %{}

  @doc "`MobBucketItem.spawn`: apply the item components and its bucket tag to a new body."
  def release(%ItemStack{item_id: item} = stack) do
    with type when is_binary(type) <- type(item),
         {:ok, body} <- Body.new(type) do
      tag =
        case ItemStack.component(stack, "minecraft:bucket_entity_data") do
          {:compound, fields} -> fields
          _ -> %{}
        end

      # These shared flags have no modelled body semantics yet. Refuse an
      # explicitly requested flag rather than silently losing it on release.
      if Enum.any?(~w(Silent Glowing Invulnerable), &(number(tag[&1], 0) != 0)) do
        {:error, :unsupported_bucket_flags}
      else
        {:ok, restore(body, stack, tag)}
      end
    else
      _ -> {:error, :not_mob_bucket}
    end
  end

  @doc "Finalize the spawn before applying its saved components/data, keeping level random draws."
  def spawn(stack, uuid, {x, y, z}, world) do
    with {:ok, loaded} <- release(stack),
         {:ok, initial} <- Body.new(loaded.type) do
      {f, random} = Random.float(world.random)
      yaw = Valimc.AI.Mth.wrap(Valimc.Data.Float32.round(f * 360.0))
      {width, height, eye} = Body.dimensions(initial)

      made =
        Valimc.AI.Spawn.finalize(%Self{
          uuid: uuid,
          type: initial.type,
          x: x,
          y: y,
          z: z,
          yaw: yaw,
          head: yaw,
          pitch: 0.0,
          on_ground: false,
          velocity: {0.0, 0.0, 0.0},
          mob: %{initial.mob | finalize: :bucket},
          mind: Valimc.AI.mind(initial.type, uuid, nil, initial.data),
          facts: Valimc.AI.Facts.mob(initial.type),
          width: width,
          height: height,
          eye: eye,
          world: %{world | random: random},
          data: initial.data
        })

      initial = %{
        initial
        | yaw: yaw,
          head_yaw: yaw,
          data: made.data,
          mob: %{made.mob | ai: made.mind}
      }

      {:compound, tag} =
        ItemStack.component(stack, "minecraft:bucket_entity_data") || {:compound, %{}}

      {:ok, restore(initial, stack, tag), made.world}
    end
  end

  defp restore(%Body{type: type, mob: mob} = body, stack, tag) do
    health = mob.living.health
    value = min(health.maximum, max(0.0, number(tag["Health"], health.value)))
    health = %{health | value: value * 1.0}

    mob = %{
      mob
      | living: %{mob.living | health: health},
        no_ai: number(tag["NoAI"], 0) != 0,
        persistent: number(tag["PersistenceRequired"], 0) != 0
    }

    data = Map.put(body.data, :from_bucket, true)

    data =
      case type do
        "minecraft:salmon" ->
          Map.put(data, :size, component(stack, "salmon/size", data.size))

        "minecraft:axolotl" ->
          data
          |> Map.put(:variant, component(stack, "axolotl/variant", data.variant))
          |> Map.put(:age, trunc(number(tag["Age"], 0)))
          |> Map.put(:age_locked, number(tag["AgeLocked"], 0) != 0)

        "minecraft:tropical_fish" ->
          pattern = component(stack, "tropical_fish/pattern", band(data.variant, 0xFFFF))
          base = component(stack, "tropical_fish/base_color", band(data.variant >>> 16, 255))
          color = component(stack, "tropical_fish/pattern_color", band(data.variant >>> 24, 255))
          Map.put(data, :variant, pattern + (base <<< 16) + (color <<< 24))

        _ ->
          data
      end

    mob =
      if type == "minecraft:axolotl", do: restore_cooldown(mob, tag["HuntingCooldown"]), else: mob

    %{
      body
      | mob: mob,
        data: data,
        no_gravity: number(tag["NoGravity"], 0) != 0,
        custom_name: ItemStack.component(stack, "minecraft:custom_name")
    }
  end

  defp restore_cooldown(mob, value) do
    ttl = if value != nil, do: trunc(number(value, 0))

    update = fn memories ->
      if ttl != nil,
        do: Map.put(memories, :has_hunting_cooldown, {true, ttl}),
        else: Map.delete(memories, :has_hunting_cooldown)
    end

    case mob.ai do
      %Mind{brain: brain} = mind ->
        %{mob | ai: %{mind | brain: %{brain | memories: update.(brain.memories)}}}

      kept ->
        kept = kept || %{random: Random.new(:crypto.strong_rand_bytes(16))}
        %{mob | ai: Map.put(kept, :memories, update.(Map.get(kept, :memories, %{})))}
    end
  end

  defp component(stack, name, default),
    do: ItemStack.component(stack, "minecraft:" <> name) || default

  defp number({type, n}, _default) when type in [:byte, :short, :int, :long], do: n
  defp number({:float, <<n::float-32>>}, _default), do: n
  defp number({:double, <<n::float-64>>}, _default), do: n
  defp number(_, default), do: default
end
