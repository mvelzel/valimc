defmodule Valimc.World.ItemPortals do
  @moduledoc """
  Entities in portals (VMC-026c), as vanilla's `ItemEntity` uses them, for the
  region owner that simulates them:

  - A simulated step that meets a portal on its way (`Valimc.Portal.Contact`,
    over the owner's own blocks) renews the item's portal cooldown when it
    runs (300 ticks, `getDimensionChangingDelay`). Off cooldown the item
    travels at once (non-players have no portal time), one item per owner at
    a time: its cooldown starts and its destination is found in a pooled job.
  - The job runs `Valimc.Portal.Destination`, `EndPortal` or
    `GatewayDestination` with the item's size (0.25 × 0.25), creating exit
    portals and gateways and the End's platform as vanilla's do.
  - Its target becomes the item's step at the arrival: a handoff to another
    dimension (tagged) or region (plain), or a local move. The arrival keeps
    the item's stack, age and pickup delay, with a fresh cooldown.
  """
  alias Valimc.{Dimension, ItemMotionState, World}
  alias Valimc.Portal.{Contact, Destination, EndPortal, GatewayDestination}
  alias Valimc.World.Entities

  @cooldown 300
  @size {0.25, 0.25}
  @deadline 60_000

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

      case Contact.touched(&Contact.box(@size, &1), from, step.position, read) do
        nil ->
          {step, travel}

        touch ->
          cond do
            step.motion.portal_cooldown > 0 -> {renew(step), travel}
            free and travel == nil -> {step, {step, entry, touch}}
            true -> {step, travel}
          end
      end
    end)
  end

  @doc "A step with the portal cooldown started (`setPortalCooldown`)."
  def renew(step), do: %{step | motion: %{step.motion | portal_cooldown: @cooldown}}

  @doc """
  The owner job finding a travelling item's destination (`{:ok, target}` or an
  error); it may take up to `deadline/0`.
  """
  def work({step, _entry, {kind, cell}}) do
    travel = %{
      kind: kind,
      entry: cell,
      position: step.position,
      velocity: step.motion.velocity,
      # ValiMC items have no yaw (vanilla's is random from spawn).
      yaw: 0.0,
      pitch: 0.0,
      dimensions: @size,
      entity: :item,
      spectator: false
    }

    fn -> destination(travel) end
  end

  def deadline, do: @deadline

  defp destination(%{kind: :nether_portal} = travel), do: Destination.nether(travel)
  defp destination(%{kind: :end_portal} = travel), do: EndPortal.destination(travel)
  defp destination(%{kind: :end_gateway} = travel), do: GatewayDestination.destination(travel)

  @doc """
  The travelled item's step at its target: `{:handoff, destination, step}`
  (a `{dimension, key}` address in another dimension, a plain region key in
  this one), `{:local, step}`, or `:gone` once the item no longer exists.
  """
  def arrival(items, key, uuid, target) do
    case Entities.find(items, uuid) do
      {:ok, {_epoch, id, revision}} ->
        entry = items.entries[id]
        motion = Map.get(entry, :motion, %ItemMotionState{no_gravity: entry.no_gravity})

        step = %{
          id: id,
          revision: revision,
          position: {target.x, target.y, target.z},
          motion: %{motion | velocity: target.velocity, portal_cooldown: @cooldown}
        }

        region = World.region_key(World.chunk_key(target.x, target.z))

        cond do
          target.dimension != Dimension.current() -> {:handoff, {target.dimension, region}, step}
          region != key -> {:handoff, region, step}
          true -> {:local, step}
        end

      _ ->
        :gone
    end
  end
end
