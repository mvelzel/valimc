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

  @doc "The physical box at `{x, y, z}` (`Body.box/2`)."
  def box(%__MODULE__{dimensions: {w, h, _}}, {x, y, z}),
    do: {x - w / 2, y, z - w / 2, x + w / 2, y + h, z + w / 2}

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
