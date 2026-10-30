defmodule Valimc.World.EntityPortals do
  @moduledoc """
  Entities in portals: items (VMC-026c), experience orbs and mobs (VMC-026d),
  as vanilla's non-player entities use them, for the region owner that
  simulates them:

  - A simulated step that meets a portal on its way (`Valimc.World.Portal.Contact`,
    over the owner's own blocks, with the entity's size) renews its portal
    cooldown when it runs (300 ticks, `getDimensionChangingDelay`). Off
    cooldown the entity travels at once (non-players have no portal time),
    one per owner at a time: its cooldown starts and its destination is found
    in a pooled job. A dead mob and the bosses (`canUsePortal`) do not travel.
  - The job runs `Valimc.World.Portal.Destination`, `EndPortal` or
    `GatewayDestination` with the entity's size, creating exit portals and
    gateways and the End's platform as vanilla's do.
  - Its target becomes the entity's step at the arrival: a handoff to another
    dimension (tagged) or region (plain), or a local move. The arrival keeps
    the entity's record (an item's stack, age and pickup delay; an orb's
    value and count; a mob's health, equipment and memory, its mind starting
    afresh as a handoff's does) with the target's motion and rotation and a
    fresh cooldown.

  Items and orbs keep their cooldown in their motion, bodies in the body.
  """
  alias Valimc.Data.{EntityTypes, Grid}
  alias Valimc.Entity.{Body, ItemMotionState, Store}
  alias Valimc.World.Portal.{Contact, Destination, EndPortal, GatewayDestination}

  @cooldown 300
  @deadline 60_000
  @bosses ["minecraft:ender_dragon", "minecraft:wither"]

  def cooldown, do: @cooldown

  @doc """
  The steps with the cooldowns of those touching a portal renewed, and the
  touch of one off cooldown to travel (`{step, entry, {kind, cell}}`, or nil;
  only when `free`). `read.(cells)` gives the owner's states.
  """
  def contacts(steps, entries, read, free) do
    Enum.map_reduce(steps, nil, fn step, travel ->
      entry = entries[step.id]
      from = {entry.entity.x, entry.entity.y, entry.entity.z}
      size = size(entry)

      case size && Contact.touched(&Contact.box(size, &1), from, step.position, read) do
        nil ->
          {step, travel}

        touch ->
          cond do
            cooldown(step) > 0 -> {renew(step), travel}
            free and travel == nil -> {step, {step, entry, touch}}
            true -> {step, travel}
          end
      end
    end)
  end

  # The entity's width and height; nil for one that never travels.
  defp size(%{kind: :item}), do: {0.25, 0.25}
  defp size(%{kind: :orb}), do: {0.5, 0.5}

  defp size(%{kind: :mob, body: %Valimc.Entity.NativeBody{type: type, alive: true}})
       when type not in @bosses do
    %{width: width, height: height} = EntityTypes.fetch(type)
    {width, height}
  end

  defp size(%{kind: :mob, body: %Body{type: type} = body}) when type not in @bosses do
    if Body.alive?(body) do
      %{width: width, height: height} = EntityTypes.fetch(type)
      {width, height}
    end
  end

  defp size(_entry), do: nil

  defp cooldown(%{body: %Body{portal_cooldown: cooldown}}), do: cooldown
  defp cooldown(%{body: %Valimc.Entity.NativeBody{portal_cooldown: cooldown}}), do: cooldown
  defp cooldown(%{motion: %{portal_cooldown: cooldown}}), do: cooldown

  @doc "A step with the portal cooldown started (`setPortalCooldown`)."
  def renew(%{body: %Body{} = body} = step),
    do: %{step | body: %{body | portal_cooldown: @cooldown}}

  # A native mob's (VMC-081d): its section takes the cooldown with the step.
  def renew(%{body: %Valimc.Entity.NativeBody{} = row} = step),
    do: Map.delete(%{step | body: %{row | portal_cooldown: @cooldown}}, :native)

  def renew(step), do: %{step | motion: %{step.motion | portal_cooldown: @cooldown}}

  @doc """
  The owner job finding a travelling entity's destination (`{:ok, target}` or
  an error); it may take up to `deadline/0`.
  """
  def work({step, entry, {kind, cell}}) do
    {velocity, yaw, pitch} =
      case step do
        %{body: body} -> {body.velocity, body.yaw, body.pitch}
        # ValiMC items and orbs have no yaw (vanilla's is random from spawn).
        _ -> {step.motion.velocity, 0.0, 0.0}
      end

    travel = %{
      kind: kind,
      entry: cell,
      position: step.position,
      velocity: velocity,
      yaw: yaw,
      pitch: pitch,
      dimensions: size(entry),
      entity: entry.kind,
      spectator: false
    }

    fn -> destination(travel) end
  end

  def deadline, do: @deadline

  defp destination(%{kind: :nether_portal} = travel), do: Destination.nether(travel)
  defp destination(%{kind: :end_portal} = travel), do: EndPortal.destination(travel)
  defp destination(%{kind: :end_gateway} = travel), do: GatewayDestination.destination(travel)

  @doc """
  The travelled entity's step at its target, for an entity of section `key`:
  `{:handoff, destination section, step}`, `{:local, step}`, or `:gone` once
  the entity no longer exists.
  """
  def arrival(entities, key, uuid, target) do
    case Store.find(entities, uuid) do
      {:ok, {_epoch, id, revision}} ->
        step = %{id: id, revision: revision, position: {target.x, target.y, target.z}}
        step = Map.merge(step, moved(entities.entries[id], target))

        case Grid.section(target.dimension, Grid.chunk_key(target.x, target.z)) do
          ^key -> {:local, step}
          destination -> {:handoff, destination, step}
        end

      _ ->
        :gone
    end
  end

  defp moved(%{body: %Valimc.Entity.NativeBody{} = row}, target) do
    %{
      body: %{
        row
        | velocity: target.velocity,
          yaw: target.yaw,
          head_yaw: target.yaw,
          pitch: target.pitch,
          portal_cooldown: @cooldown
      }
    }
  end

  defp moved(%{body: %Body{} = body}, target) do
    %{
      body: %{
        body
        | velocity: target.velocity,
          yaw: target.yaw,
          head_yaw: target.yaw,
          pitch: target.pitch,
          portal_cooldown: @cooldown
      }
    }
  end

  defp moved(entry, target) do
    motion = Map.get(entry, :motion) || %ItemMotionState{no_gravity: entry.no_gravity}
    %{motion: %{motion | velocity: target.velocity, portal_cooldown: @cooldown}}
  end
end
