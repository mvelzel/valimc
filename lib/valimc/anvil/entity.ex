defmodule Valimc.Anvil.Entity do
  @moduledoc """
  Vanilla entities (the `Entities` lists of `entities/` region files) as ValiMC
  holds them (VMC-021e2).

  A dropped item ValiMC can represent becomes an item record of the entity model
  (`Valimc.World.Items`), read as vanilla's `Entity.load` and
  `ItemEntity.readAdditionalSaveData` read it: a motion component beyond ±10 is
  zero, `Age` and `PickupDelay` are shorts. Every other entity (mobs, XP orbs,
  items with an owner, riders or components ValiMC cannot hold) is preserved as
  its compound for export.
  """
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemData
  alias Valimc.World.Items

  @doc "`{:item, record}` for an importable dropped item, `:preserve` otherwise."
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
        no_gravity: flag(fields["NoGravity"])
      }

      {:item, %{uuid: uuid, x: x, y: y, z: z, stack: stack, motion: state}}
    else
      _ -> :preserve
    end
  end

  def convert(_), do: :preserve

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

  defp flag({:byte, value}), do: value != 0
  defp flag(_), do: false

  @doc "An item record's compound for an entities file (export)."
  def item_tag(%{uuid: uuid, x: x, y: y, z: z, stack: stack} = record) do
    motion = Map.get(record, :motion) || %ItemMotionState{}
    {vx, vy, vz} = motion.velocity

    {:compound,
     %{
       "id" => {:string, "minecraft:item"},
       "UUID" => {:int_array, uuid},
       "Pos" => {:list, {:double, [<<x::float-64>>, <<y::float-64>>, <<z::float-64>>]}},
       "Motion" =>
         {:list,
          {:double, [<<vx * 1.0::float-64>>, <<vy * 1.0::float-64>>, <<vz * 1.0::float-64>>]}},
       "Rotation" => {:list, {:float, [<<0.0::float-32>>, <<0.0::float-32>>]}},
       "FallDistance" => {:double, <<0.0::float-64>>},
       "Fire" => {:short, -1},
       "Air" => {:short, 300},
       "OnGround" => {:byte, if(motion.on_ground, do: 1, else: 0)},
       "NoGravity" => {:byte, if(motion.no_gravity, do: 1, else: 0)},
       "Invulnerable" => {:byte, 0},
       "PortalCooldown" => {:int, 0},
       "Health" => {:short, 5},
       "Age" => {:short, motion.age},
       "PickupDelay" => {:short, motion.pickup_delay},
       "Item" => ItemData.tag(stack)
     }}
  end
end
