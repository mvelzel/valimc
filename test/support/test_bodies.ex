defmodule Valimc.TestBodies do
  @moduledoc """
  A store entry's body as tests read it (VMC-081d): a native mob's restored
  from its section's record, with the lead its row shows held; any other
  entry's own body. Native sections' records are readable from any process.
  """
  alias Valimc.Entity.{Body, NativeBody, Store}
  alias Valimc.Native

  def body(%{body: %NativeBody{leash: leash}, native: ref, entity: %{entity_id: id}} = entry) do
    {:ok, body} = Body.restore(Store.record(entry))

    # Its health as it is, hurt cooldown included.
    {value, maximum, hurt, death, cooldown, last} = Native.mob_section_oracle_health(ref, id)

    health = %{
      body.mob.living.health
      | value: value,
        maximum: maximum,
        hurt_ticks: hurt,
        death_ticks: death,
        cooldown: cooldown,
        last_hurt: last
    }

    body = put_in(body.mob.living.health, health)

    case {leash, body.mob.leash} do
      {%{} = shown, %{} = restored} ->
        put_in(body.mob.leash, %{restored | id: shown.id, restored: shown.restored})

      _ ->
        body
    end
  end

  def body(%{body: body}), do: body

  @doc """
  The store with entry `id`'s body as `fun` makes it of `body/1`'s, in the
  owner's process: a native mob is restored in its section from the changed
  body's record (with its health's cooldown and last hurt; its mind's live
  state beside its record starts again), its row the store's; any other
  entry's body changes in place.
  """
  def replace(store, id, fun) do
    case store.entries[id] do
      %{body: %NativeBody{}, native: ref, entity: e} = entry ->
        body = fun.(body(entry))
        record = Store.body_record(body, e.uuid, {e.x, e.y, e.z})
        health = body.mob.living.health
        cooldown = {health.cooldown, health.last_hurt * 1.0}
        {_, row} = Native.mob_section_oracle_put(ref, id, record, cooldown)
        Store.change_body(store, id, row)

      entry ->
        Store.change_body(store, id, fun.(body(entry)))
    end
  end

  @doc """
  The entry with its body as `body/1` reads it, and a native mob's idle and
  lived counts, which its section keeps.
  """
  def entry(%{body: %NativeBody{}, native: ref, entity: %{entity_id: id}} = entry) do
    {_, _, idle, lived} = Native.mob_section_body(ref, id)
    Map.merge(%{entry | body: body(entry)}, %{idle: idle, lived: lived})
  end

  def entry(entry), do: entry

  @doc "A schooling fish's school (`Fish.school/1`; a native mind's from its section)."
  def school(%{native: ref, entity: %{entity_id: id}, body: %NativeBody{}}) do
    own =
      case Native.mob_section_oracle_mind(ref, id) do
        %{own: own} when is_map(own) -> own
        _ -> %{}
      end

    Map.merge(%{leader: nil, school: 1}, Map.take(own, [:leader, :school]))
  end

  def school(%{body: %{mob: %{ai: mind}}}), do: Valimc.AI.Mobs.Fish.school(mind)

  @doc "Whether goal `module` runs in the entry's mind (a native mind's by name)."
  def running?(%{native: ref, entity: %{entity_id: id}, body: %NativeBody{}}, module) do
    [{_, goals, _, _, _}] = Native.mob_section_oracle_minds(ref, [id])
    inspect(module) in goals
  end

  def running?(%{body: %{mob: %{ai: %Valimc.AI.Mind{goals: goals}}}}, module),
    do: Enum.any?(Tuple.to_list(goals), &(&1.running and &1.module == module))

  def running?(_entry, _module), do: false

  @doc """
  The store with entry `id` changed beside its record, in the owner's
  process: `{:no_ai, flag}`, `{:cooldown, ticks}` (its hurt cooldown) or
  `{:move_to, {x, y, z}, speed}` (its move control's wanted position,
  `MobMotion.move_to/3`); a native mob's in its section (its mind kept), its
  row the store's.
  """
  def set(store, id, change) do
    case {store.entries[id], change} do
      {%{body: %NativeBody{}, native: ref}, _} ->
        {_, row} = Native.mob_section_oracle_set(ref, id, change)
        Store.change_body(store, id, row)

      {%{body: body}, {:no_ai, flag}} ->
        Store.change_body(store, id, put_in(body.mob.no_ai, flag))

      {%{body: body}, {:cooldown, ticks}} ->
        Store.change_body(store, id, put_in(body.mob.living.health.cooldown, ticks))

      {%{body: body}, {:move_to, target, speed}} ->
        motion = Valimc.Entity.MobMotion.move_to(body.mob.motion, target, speed)
        Store.change_body(store, id, put_in(body.mob.motion, motion))
    end
  end

  @doc """
  The entry's brain memories, `%{name => {value, ttl}}` as the Elixir brain
  keeps them (a native brain's from its section); nil without a brain.
  """
  def memories(%{native: ref, entity: %{entity_id: id}, body: %NativeBody{}}) do
    case Native.mob_section_oracle_brain_view(ref, id) do
      {_, _, _, memories} ->
        Map.new(memories, fn {name, value, ttl} -> {String.to_atom(name), {value, ttl}} end)

      nil ->
        nil
    end
  end

  def memories(%{body: %{mob: %{ai: %Valimc.AI.Mind{brain: %{memories: memories}}}}}),
    do: memories

  def memories(_entry), do: nil

  @doc "The value of the entry's brain memory `name`, nil where it has none."
  def memory(entry, name) do
    case memories(entry) do
      %{^name => {value, _}} -> value
      _ -> nil
    end
  end

  @doc "The entry's brain's activity (`Brain.activity/1`; a native brain's from its section)."
  def activity(%{native: ref, entity: %{entity_id: id}, body: %NativeBody{}}) do
    case Native.mob_section_oracle_brain_view(ref, id) do
      {_, activity, _, _} -> activity
      nil -> nil
    end
  end

  def activity(%{body: %{mob: %{ai: %Valimc.AI.Mind{brain: brain} = mind}}}) when brain != nil,
    do: Valimc.AI.Brain.activity(%Valimc.AI.Self{mind: mind})

  def activity(_entry), do: nil

  @doc "The nodes of the entry's navigation path, nil without one (a native mind's from its section)."
  def path(%{native: ref, entity: %{entity_id: id}, body: %NativeBody{}}),
    do: Native.mob_section_oracle_path(ref, id)

  def path(%{body: %{mob: %{ai: %Valimc.AI.Mind{navigation: %{path: %{nodes: nodes}}}}}}),
    do: Tuple.to_list(nodes)

  def path(_entry), do: nil

  @doc "The entry's mind's target (a native mind's from its section)."
  def target(%{native: ref, entity: %{entity_id: id}, body: %NativeBody{}}) do
    case Native.mob_section_oracle_mind(ref, id) do
      nil -> nil
      mind -> mind.target
    end
  end

  def target(%{body: %{mob: %{ai: %{target: target}}}}), do: target
  def target(_entry), do: nil
end
