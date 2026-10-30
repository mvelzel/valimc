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

  @doc "The entry with its body as `body/1` reads it."
  def entry(%{body: %NativeBody{}} = entry), do: %{entry | body: body(entry)}
  def entry(entry), do: entry

  @doc "Whether goal `module` runs in the entry's mind (a native mind's by name)."
  def running?(%{native: ref, entity: %{entity_id: id}, body: %NativeBody{}}, module) do
    [{_, goals, _, _, _}] = Native.mob_section_oracle_minds(ref, [id])
    inspect(module) in goals
  end

  def running?(%{body: %{mob: %{ai: %Valimc.AI.Mind{goals: goals}}}}, module),
    do: Enum.any?(Tuple.to_list(goals), &(&1.running and &1.module == module))

  def running?(_entry, _module), do: false

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
