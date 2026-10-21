defmodule Valimc.Anvil.Entity do
  @moduledoc """
  Vanilla entities (the `Entities` lists of `entities/` region files) as ValiMC
  holds them (VMC-021e2).

  A dropped item ValiMC can represent becomes an item record of the entity model
  (`Valimc.World.Items`), read as vanilla's `Entity.load` and
  `ItemEntity.readAdditionalSaveData` read it: a motion component beyond ±10 is
  zero, `Age` and `PickupDelay` are shorts. An XP orb becomes an imported orb
  birth (VMC-021e4, `CookingOrbs.import_orbs/3`) with its UUID, value, count and
  body. Every other entity (mobs, items with an owner, riders or components
  ValiMC cannot hold) is preserved as its compound for export.
  """
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemData
  alias Valimc.World.Items

  @doc """
  `{:item, record}` for an importable dropped item, `{:orb, orb}` for an XP orb,
  `:preserve` otherwise.
  """
  def convert({:compound, %{"id" => {:string, "minecraft:experience_orb"}} = fields}) do
    with nil <- fields["Passengers"],
         {:ok, uuid} <- uuid(fields["UUID"]),
         {:ok, position} <- doubles(fields["Pos"]),
         true <- Items.valid_position?(position),
         {:ok, motion} <- motion(fields["Motion"]),
         {:short, value} when value in 1..32_767 <- fields["Value"],
         count when count in 1..2_147_483_647 <- orb_count(fields["Count"]) do
      {:orb,
       %{
         uuid: uuid,
         position: position,
         velocity: motion,
         # Vanilla discards an orb at age 6,000; one saved there goes on the next tick.
         age: min(age(fields["Age"]), 5999),
         value: value,
         count: count,
         on_ground: flag(fields["OnGround"]),
         no_gravity: flag(fields["NoGravity"])
       }}
    else
      _ -> :preserve
    end
  end

  def convert({:compound, fields}) do
    with {:string, "minecraft:item"} <- fields["id"],
         nil <- fields["Owner"],
         nil <- fields["Passengers"],
         {:ok, uuid} <- uuid(fields["UUID"]),
         {:ok, {x, y, z} = position} <- doubles(fields["Pos"]),
         true <- Items.valid_position?(position),
         {:ok, motion} <- motion(fields["Motion"]),
         {:ok, stack} when stack != nil <- ItemData.stack(fields["Item"]) do
      state = %ItemMotionState{
        velocity: motion,
        age: age(fields["Age"]),
        pickup_delay: delay(fields["PickupDelay"]),
        on_ground: flag(fields["OnGround"]),
        no_gravity: flag(fields["NoGravity"]),
        portal_cooldown: cooldown(fields["PortalCooldown"])
      }

      {:item, %{uuid: uuid, x: x, y: y, z: z, stack: stack, motion: state}}
    else
      _ -> :preserve
    end
  end

  def convert(_), do: :preserve

  defp orb_count(nil), do: 1
  defp orb_count({:int, count}), do: count
  defp orb_count(_), do: 0

  @doc "The 16 UUID bytes of a vanilla `[I; a, b, c, d]`."
  def uuid({:int_array, <<_::128>> = uuid}), do: {:ok, uuid}
  def uuid(_), do: :error

  defp doubles({:list, {:double, [<<x::float-64>>, <<y::float-64>>, <<z::float-64>>]}}),
    do: {:ok, {x, y, z}}

  defp doubles(_), do: :error

  defp motion(nil), do: {:ok, {0.0, 0.0, 0.0}}

  defp motion(tag) do
    with {:ok, {x, y, z}} <- doubles(tag), do: {:ok, {clamp(x), clamp(y), clamp(z)}}
  end

  defp clamp(v) when abs(v) > 10.0, do: 0.0
  defp clamp(v), do: v

  # Vanilla discards an item once its age reaches 6,000 (-32,768 never ages).
  defp age({:short, age}), do: min(age, 6000)
  defp age(_), do: 0

  # A negative delay never counts down nor reaches 0: the item can never be picked
  # up, which ValiMC writes as the infinite delay.
  defp delay({:short, delay}) when delay < 0, do: 32_767
  defp delay({:short, delay}), do: delay
  defp delay(_), do: 0

  defp cooldown({:int, ticks}), do: ticks |> max(0) |> min(32_767)
  defp cooldown(_), do: 0

  defp flag({:byte, value}), do: value != 0
  defp flag(_), do: false

  @doc "An item record's compound for an entities file (export), with vanilla's fields."
  def item_tag(%{uuid: uuid, x: x, y: y, z: z, stack: stack} = record) do
    motion = Map.get(record, :motion) || %ItemMotionState{}

    {:compound, fields} =
      base(
        "minecraft:item",
        uuid,
        {x, y, z},
        motion.velocity,
        motion.on_ground,
        motion.no_gravity
      )

    # Vanilla saves the portal cooldown only while it runs.
    cooldown =
      if motion.portal_cooldown > 0,
        do: %{"PortalCooldown" => {:int, motion.portal_cooldown}},
        else: %{}

    {:compound,
     fields
     |> Map.merge(%{
       "Age" => {:short, motion.age},
       "PickupDelay" => {:short, motion.pickup_delay},
       "Item" => ItemData.tag(stack)
     })
     |> Map.merge(cooldown)}
  end

  @doc "An XP orb's compound for an entities file (export)."
  def orb_tag(uuid, value, count, %{position: position, velocity: velocity, age: age} = body) do
    {:compound, fields} =
      base("minecraft:experience_orb", uuid, position, velocity, body.on_ground, body.no_gravity)

    {:compound,
     Map.merge(fields, %{
       "Age" => {:short, age},
       "Value" => {:short, value},
       "Count" => {:int, count}
     })}
  end

  # The fields every entity saves (`Entity.saveWithoutId`); NoGravity only when set.
  defp base(id, uuid, {x, y, z}, {vx, vy, vz}, on_ground, no_gravity) do
    fields = %{
      "id" => {:string, id},
      "UUID" => {:int_array, uuid},
      "Pos" => doubles_tag([x, y, z]),
      "Motion" => doubles_tag([vx, vy, vz]),
      "Rotation" => {:list, {:float, [<<0.0::float-32>>, <<0.0::float-32>>]}},
      "fall_distance" => {:double, <<0.0::float-64>>},
      "Fire" => {:short, 0},
      "Air" => {:short, 300},
      "OnGround" => {:byte, if(on_ground, do: 1, else: 0)},
      "Invulnerable" => {:byte, 0},
      "PortalCooldown" => {:int, 0},
      "Health" => {:short, 5}
    }

    {:compound, if(no_gravity, do: Map.put(fields, "NoGravity", {:byte, 1}), else: fields)}
  end

  defp doubles_tag(values), do: {:list, {:double, Enum.map(values, &<<&1 * 1.0::float-64>>)}}
end
