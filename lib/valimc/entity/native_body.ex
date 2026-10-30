defmodule Valimc.Entity.NativeBody do
  @moduledoc """
  What a store keeps of a native mob (VMC-081d): the row its section's
  native mobs (`Valimc.Entity.NativeMobs`) publish whenever it changes, in
  place of a `Valimc.Entity.Body`. Routing, sensing, spawning and
  publication read it as they read a body: its type, rotations, motion and
  ground, whether it is alive, its dimensions, name, portal cooldown,
  persistence, the bucket flag, what observers are shown of it (`shown`:
  `Body.shown/1`'s projection, `{values, synced attributes, equipment,
  link}`), what other mobs sense of it, the attribute values its owner's
  pushes and explosions read, whether a death waits to drop and its lead
  (`leash`: nil or `%{holder, id, restored}`, `Valimc.Entity.Leashes`).

  Its state lives in Rust; every change goes through its section's
  resource, never through this row.
  """
  alias Valimc.Data.Float32
  alias Valimc.Entity.Mob
  alias Valimc.Protocol.{EntityPackets, Packets}

  defstruct [
    :type,
    :yaw,
    :pitch,
    :head_yaw,
    :velocity,
    :on_ground,
    :no_gravity,
    :alive,
    :dimensions,
    :custom_name,
    :portal_cooldown,
    :persistent,
    :from_bucket,
    :shown,
    :in_water,
    :killed_by,
    :recent,
    :data,
    :target,
    :knockback_resistance,
    :explosion_resistance,
    :step_height,
    :gravity,
    :death,
    :no_ai,
    :idle,
    :leash
  ]

  @doc "A new row over `previous`: a nil `shown` keeps what was shown."
  def merge(%__MODULE__{shown: nil} = row, %__MODULE__{shown: shown}), do: %{row | shown: shown}
  def merge(%__MODULE__{} = row, _previous), do: row

  @doc """
  The physical box at `{x, y, z}` (`Body.box/2`): a shulker's opens with its
  lid toward the face opposite its attachment (`getProgressAabb` of its
  physical peek).
  """
  def box(
        %__MODULE__{type: "minecraft:shulker", data: %{attach_face: face, peek_amount: peek}},
        at
      ),
      do: progress_box(Bitwise.bxor(face, 1), physical_peek(peek), at)

  def box(%__MODULE__{dimensions: {w, h, _}}, {x, y, z}),
    do: {x - w / 2, y, z - w / 2, x + w / 2, y + h, z + w / 2}

  @doc "The box a living shulker blocks others with (`canBeCollidedWith`), else nil."
  def collider(%__MODULE__{type: "minecraft:shulker", alive: true} = row, at), do: box(row, at)
  def collider(_row, _at), do: nil

  @pi Float32.round(:math.pi())
  # `Direction` steps by 3D value.
  @steps {{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}}

  # `getPhysicalPeek`: `0.5F - Mth.sin((0.5F + amount) * (float)Math.PI) * 0.5F`.
  defp physical_peek(amount) do
    angle = Float32.round(Float32.round(0.5 + amount) * @pi)
    Float32.round(0.5 - Float32.round(Valimc.Data.Mth.sin(angle) * 0.5))
  end

  # `getProgressAabb(1, direction, progress, position)`.
  defp progress_box(direction, progress, {x, y, z}) do
    {dx, dy, dz} = elem(@steps, direction)

    grow = fn low, high, d ->
      if d > 0, do: {low, high + d * progress}, else: {low + d * progress, high}
    end

    {x0, x1} = grow.(-0.5, 0.5, dx)
    {y0, y1} = grow.(0.0, 1.0, dy)
    {z0, z1} = grow.(-0.5, 0.5, dz)
    {x0 + x, y0 + y, z0 + z, x1 + x, y1 + y, z1 + z}
  end

  @doc "`Body.pairing/2` of a native mob: its non-default data, synced attributes, equipment and link."
  def pairing(id, %__MODULE__{shown: {values, synced, equipment, link}}) do
    data = for {field, value, default} <- values, value != default, do: {field, value}
    data = if data == [], do: [], else: [EntityPackets.metadata(id, data)]
    changes = Mob.equipment_changes(equipment, %{})

    (data ++
       [Packets.attributes(id, synced)] ++
       if(changes == [], do: [], else: [EntityPackets.equipment(id, changes)]) ++
       if(link == nil, do: [], else: [EntityPackets.link(id, link)]))
    |> Enum.map(&binary/1)
  end

  @doc "`Body.shown_changes/3` of a native mob between two rows."
  def shown_changes(
        id,
        %__MODULE__{shown: {old_values, old_synced, old_eq, old_link}},
        %__MODULE__{
          shown: {values, synced, equipment, link}
        }
      ) do
    data =
      for {{field, value, _}, {_, before, _}} <- Enum.zip(values, old_values),
          value != before,
          do: {field, value}

    data = if data == [], do: [], else: [EntityPackets.metadata(id, data)]
    changed = synced -- old_synced
    equipment = Mob.equipment_changes(equipment, old_eq)
    link = if old_link == link, do: [], else: [EntityPackets.link(id, link)]

    (data ++
       if(changed == [], do: [], else: [Packets.attributes(id, changed)]) ++
       if(equipment == [], do: [], else: [EntityPackets.equipment(id, equipment)]) ++ link)
    |> Enum.map(&binary/1)
  end

  defp binary({id, payload}), do: {id, IO.iodata_to_binary(payload)}
end
