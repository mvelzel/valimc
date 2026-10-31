defmodule Valimc.Commands.Entities do
  @moduledoc """
  Commands over bodies, the entities beyond players (VMC-043a; dropped items
  and experience orbs too, VMC-043a1): `/summon` of a modelled type, and what
  `/kill` and `/teleport` do to the bodies they select. Each body changes
  through the group owning its section; selection reads published views
  (`Commands.Targets`).
  """
  alias Valimc.Commands.{Feedback, Players, Source}
  alias Valimc.Data.{EntityTypes, Grid}
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Text
  alias Valimc.Text.Error
  alias Valimc.World
  alias Valimc.World.Region

  @doc "`/summon <entity> [<pos>] [<nbt>]` (`SummonCommand`) for modelled types."
  def summon(%{"entity" => type} = arguments, source) do
    {x, _, z} = position = position(arguments, source)
    facts = EntityTypes.fetch(type)

    unless facts.summonable, do: Error.fail!("entity.not_summonable", [type])

    unless Players.spawnable?(position), do: Error.fail!("commands.summon.invalidPosition")

    {difficulty, _} = World.Clock.difficulty()

    if difficulty.level == 0 and not facts.peaceful,
      do: Error.fail!("commands.summon.failed.peaceful")

    body =
      case {Body.new(type), arguments["nbt"]} do
        {{:error, :unmodelled_type}, _} -> Error.refuse!("Summoning #{type} is not supported yet")
        {{:ok, %Body{mob: nil} = body}, nil} -> body
        {{:ok, body}, nil} -> %{body | mob: %{body.mob | finalize: :command}}
        # With entity data a mob does not finish its spawn (`initialize` false).
        {{:ok, body}, {:compound, tags}} -> Enum.reduce(Enum.sort(tags), body, &entity_data/2)
      end

    record = Store.body_record(body, :crypto.strong_rand_bytes(16), position)
    section = Grid.section(source.dimension, Grid.chunk_key(x, z))

    with {:ok, owner} <- World.owner(section),
         :ok <- Region.drop_items(owner, [record]) do
      Feedback.success(
        source,
        Text.translatable("commands.summon.success", [Text.translatable(facts.description)])
      )

      1
    else
      _ -> Error.fail!("commands.summon.failed")
    end
  end

  # `/summon`'s entity data a mob reads (`Mob.readAdditionalSaveData`, VMC-083):
  # its equipment, name, `NoAI`, persistence and health, a zombie's `IsBaby`;
  # other keys are refused.
  @equipment Map.new(Valimc.Entity.Mob.slots(), fn {slot, _} -> {Atom.to_string(slot), slot} end)

  defp entity_data({"equipment", {:compound, slots}}, %Body{mob: %{} = mob} = body) do
    equipment =
      Enum.reduce(slots, mob.equipment, fn {name, item}, equipment ->
        slot = @equipment[name] || Error.refuse!("Unknown equipment slot #{name}")
        Map.put(equipment, slot, item_stack(item))
      end)

    %{body | mob: %{mob | equipment: equipment}}
  end

  defp entity_data({"CustomName", name}, %Body{mob: %{}} = body), do: Body.name(body, name)

  defp entity_data({"NoAI", flag}, %Body{mob: %{} = mob} = body),
    do: %{body | mob: %{mob | no_ai: truthy(flag)}}

  defp entity_data({"PersistenceRequired", flag}, %Body{mob: %{} = mob} = body),
    do: %{body | mob: %{mob | persistent: truthy(flag)}}

  defp entity_data({"Health", {kind, value}}, %Body{mob: %{} = mob} = body)
       when kind in [:float, :double, :int, :short, :byte] do
    value =
      case value do
        <<v::float-32>> -> v
        <<v::float-64>> -> v
        v -> v * 1.0
      end

    health = %{mob.living.health | value: min(value, mob.living.health.maximum)}
    %{body | mob: %{mob | living: %{mob.living | health: health}}}
  end

  defp entity_data({"IsBaby", flag}, %Body{data: %{baby: _} = data} = body),
    do: %{body | data: %{data | baby: truthy(flag)}}

  defp entity_data({key, _}, _body),
    do: Error.refuse!("The entity data #{key} is not supported yet")

  defp item_stack({:compound, %{"id" => {:string, id}} = item}) do
    if Map.keys(item) -- ["id", "count"] != [],
      do: Error.refuse!("Item components in entity data are not supported yet")

    count =
      case item["count"] do
        nil -> 1
        {_, count} when is_integer(count) and count > 0 -> count
        _ -> Error.refuse!("Invalid item count")
      end

    unless Valimc.Protocol.ItemTypes.known?(id), do: Error.refuse!("Unknown item #{id}")
    Valimc.Protocol.ItemStack.new(id, count)
  end

  defp item_stack(_), do: Error.refuse!("Invalid item in entity data")

  defp truthy({_, value}) when is_integer(value), do: value != 0
  defp truthy(_), do: Error.refuse!("Expected a boolean in entity data")

  defp position(%{"pos" => coordinates}, source), do: Source.position(source, coordinates)
  defp position(_arguments, source), do: source.position

  @doc "Whether a selected target is a body."
  def body?(target), do: match?(%{kind: :body}, target)

  @doc """
  `/kill` of `bodies`: `[{body, 1}]` for each its section's owner killed (a
  mob starts dying, any other body is removed); one whose owner is gone
  counts nothing.
  """
  def kill(bodies) do
    bodies
    |> Enum.group_by(& &1.section)
    |> Enum.flat_map(fn {section, targets} ->
      with {:ok, owner} <- World.existing_owner(section),
           {:ok, _} <- Region.kill_entities(owner, Enum.map(targets, & &1.uuid)) do
        Enum.map(targets, &{&1, 1})
      else
        _ -> []
      end
    end)
  end

  @doc """
  `/teleport` of `bodies` to `pose_of.(body)` (`%{x, y, z, yaw, pitch,
  dimension}`) within their dimension: `[{body, 1}]` for each moved.
  Bodies do not change dimension yet.
  """
  def teleport(bodies, pose_of) do
    Enum.flat_map(bodies, fn body ->
      pose = pose_of.(body)

      with true <- pose.dimension == body.dimension,
           {:ok, owner} <- World.existing_owner(body.section),
           :ok <-
             Region.move_entity(
               owner,
               body.uuid,
               {pose.x * 1.0, pose.y * 1.0, pose.z * 1.0},
               {pose.yaw * 1.0, pose.pitch * 1.0}
             ) do
        [{body, 1}]
      else
        _ -> []
      end
    end)
  end
end
