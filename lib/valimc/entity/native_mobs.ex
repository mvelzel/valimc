defmodule Valimc.Entity.NativeMobs do
  @moduledoc """
  A section's native mobs (VMC-081d): the `MobSection` resource
  (`valimc_core::mobs::section`) its group owns beside the section's Region
  resource and hands on with it, holding every mob of a native type whole.
  The section's store (`Valimc.Entity.Store`) keeps for such a mob its
  entry's routing and publication (network id, uuid, position, revisions,
  events, its view) with a `Valimc.Entity.NativeBody` row in place of a
  body, refreshed from the resource whenever the mob changes; every change
  to it is a call on the resource.

  Which types are native is `config :valimc, :native_mob_types` (per owner
  scope): a list of entity type names and `:plain`, every living type of a
  spawning category whose family has no Elixir AI (`Body`'s plain mobs, the
  dragon apart). A type whose family is native (`mobs::kinds`) thinks in
  Rust; the others' turns yield to `MobTicks`. A type is native or Elixir whole: as families' AI
  moves to Rust their types join the list.
  """
  alias Valimc.Data.{EffectTypes, EntityTypes}
  alias Valimc.Entity.{Body, Mob, NativeBody}
  alias Valimc.Living.Attributes
  alias Valimc.Native

  defstruct [:ref, :types]

  @doc "Install the facts native mobs read once per VM (later calls do nothing)."
  def install! do
    Valimc.Entity.NativeLiving.install!()
    Valimc.AI.Paths.install!()

    if not :persistent_term.get({__MODULE__, :installed}, false) do
      {:ok, _} = Native.mob_section_install(record_facts())
      :persistent_term.put({__MODULE__, :installed}, true)
    end

    :ok
  end

  @doc "The record codec's facts (`mob_record_facts/1`'s map)."
  def record_facts do
    types =
      for name <- EntityTypes.names(), EntityTypes.living?(name) do
        {:ok, body} = Body.generated(name, nil, false)
        {name, true, Mob.base(name, %{}, "minecraft:max_health") * 1.0, Map.keys(body.data)}
      end

    %{
      effect_count: EffectTypes.count(),
      absorption_effect: EffectTypes.id("absorption"),
      max_absorption: Attributes.max_absorption() * 1.0,
      types: types
    }
  end

  @doc """
  The plain mob types: living types of a spawning category without Elixir
  AI (`Valimc.AI.thinks?/1` false), the dragon apart.
  """
  def plain_types do
    case :persistent_term.get({__MODULE__, :plain}, nil) do
      nil ->
        plain =
          for name <- EntityTypes.names(),
              EntityTypes.living?(name),
              EntityTypes.fetch(name).category != :misc,
              name != "minecraft:ender_dragon",
              not Valimc.AI.thinks?(name),
              into: MapSet.new(),
              do: name

        :persistent_term.put({__MODULE__, :plain}, plain)
        plain

      plain ->
        plain
    end
  end

  @doc "The native types of owner scope `scope`."
  def types(scope) do
    case Valimc.config(:native_mob_types, scope) do
      nil -> MapSet.new()
      names -> names |> List.wrap() |> Enum.reduce(MapSet.new(), &add/2)
    end
  end

  defp add(:plain, set), do: MapSet.union(set, plain_types())
  defp add(name, set) when is_binary(name), do: MapSet.put(set, name)

  @doc """
  The native mobs of section `{sx, sz}` (owner scope `scope`), owned by the
  caller: nil when the scope has no native types.
  """
  def new({sx, sz}, scope) do
    types = types(scope)

    if MapSet.size(types) == 0 do
      nil
    else
      install!()
      %__MODULE__{ref: Native.mob_section_new(sx, sz), types: types}
    end
  end

  @doc "Whether mobs of `type` are native in `native`."
  def native?(nil, _type), do: false
  def native?(%__MODULE__{types: types}, type), do: MapSet.member?(types, type)

  @doc "Hand the section's native mobs to process `to` (`region_give`'s twin)."
  def give(nil, _to), do: :ok
  def give(%__MODULE__{ref: ref}, to), do: Native.mob_section_give(ref, to)

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
