defmodule Valimc.Entity.NativeMobs do
  @moduledoc """
  A section's mobs (VMC-081d): the `MobSection` resource
  (`valimc_core::mobs::section`) its group owns beside the section's Region
  resource and hands on with it, holding every mob whole. The section's
  store (`Valimc.Entity.Store`) keeps for a mob its entry's routing and
  publication (network id, uuid, position, revisions, events, its view)
  with a `Valimc.Entity.NativeBody` row, refreshed from the resource
  whenever the mob changes; every change to it is a call on the resource.
  Every living type is simulated here, its family's AI in Rust
  (`mobs::kinds`), a type without one as a plain mob.
  """
  alias Valimc.Entity.NativeBody
  alias Valimc.Native

  defstruct [:ref]

  @doc "The native mobs of section `{sx, sz}`, owned by the caller."
  def new({sx, sz}) do
    Valimc.Entity.MobFacts.install!()
    %__MODULE__{ref: Native.mob_section_new(sx, sz)}
  end

  @doc "Hand the section's native mobs to process `to` (`region_give`'s twin)."
  def give(nil, _to), do: :ok
  def give(%__MODULE__{ref: ref}, to), do: Native.mob_section_give(ref, to)

  @doc """
  One tick of the section's mobs (`Native.mob_section_tick/6`): `source`
  `{:world, world}` or an oracle's `{:scene, view, level, players,
  region}`; `mask` the simulated chunks (`simulated_mask/2`) or `:all`;
  `units` how many mobs it may take (it picks the scheduler). `{random,
  moved, changes}`.
  """
  def tick(%__MODULE__{ref: ref}, source, tick, mask, random, extra, units),
    do: Native.dispatch(:mob_section_tick, units, [ref, source, tick, mask, random, extra])

  @doc """
  One tick of the native mobs' trackers (`Native.mob_section_track/5`,
  `Valimc.Entity.Tracking`): `{frame, spawns}`.
  """
  def track(%__MODULE__{ref: ref}, mask, fresh, run, packet_ids),
    do: Native.mob_section_track(ref, mask, fresh, run, packet_ids)

  @doc "The section's simulated chunks `chunks` as the tick's 64-bit mask."
  def simulated_mask({sx, sz}, chunks) do
    Enum.reduce(chunks, 0, fn {cx, cz}, mask ->
      {lx, lz} = {cx - sx * 8, cz - sz * 8}

      if lx in 0..7 and lz in 0..7,
        do: Bitwise.bor(mask, Bitwise.bsl(1, lz * 8 + lx)),
        else: mask
    end)
  end

  @doc """
  The native mobs' timers this game tick (`Native.mob_section_age_tick/4`):
  `budget` the ticks owed by chunk. `[{id, row | nil, events, done}]`.
  """
  def age(nil, _tick, _budget, _min_y), do: []
  def age(_native, _tick, [], _min_y), do: []

  def age(%__MODULE__{ref: ref}, tick, budget, min_y),
    do: Native.mob_section_age_tick(ref, tick, budget, min_y * 1.0)

  @doc "A native mob's row as it is now, its position and idle and lived counts."
  def body(%__MODULE__{ref: ref}, id) do
    {position, row, idle, lived} = Native.mob_section_body(ref, id)
    {position, row, idle, lived}
  end

  @doc "A row over `previous` (`NativeBody.merge/2`)."
  def merge(%NativeBody{} = row, previous), do: NativeBody.merge(row, previous)

  @doc """
  The records a frame writes now and whether one still waits for the motion
  pass: `{%{{:entity, uuid} => record | :deleted}, waiting}`.
  """
  def cut(nil, _full), do: {%{}, false}

  def cut(%__MODULE__{ref: ref}, full) do
    {records, waiting} = Native.mob_section_cut(ref, full)

    {Map.new(records, fn
       {uuid, nil} -> {{:entity, uuid}, :deleted}
       {uuid, record} -> {{:entity, uuid}, record}
     end), waiting}
  end

  @doc "Every record taken as written (a checkpoint or a load holds them)."
  def baseline(nil), do: :ok
  def baseline(%__MODULE__{ref: ref}), do: Native.mob_section_baseline(ref)

  @doc "Every native mob's record."
  def records(nil), do: []
  def records(%__MODULE__{ref: ref}), do: Native.mob_section_records(ref, :all)
end
