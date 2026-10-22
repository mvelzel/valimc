defmodule Valimc.Commands.Entities do
  @moduledoc """
  Commands over bodies, the entities beyond players, items and orbs
  (VMC-043a): `/summon` of a modelled type, and what `/kill` and `/teleport`
  do to the bodies they select. Each body changes through the group owning
  its section; selection reads published views (`Commands.Targets`).
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

    if Map.has_key?(arguments, "nbt"),
      do: Error.refuse!("Summoning with entity data is not supported yet")

    body =
      case Body.new(type) do
        {:ok, body} -> body
        {:error, :unmodelled_type} -> Error.refuse!("Summoning #{type} is not supported yet")
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
