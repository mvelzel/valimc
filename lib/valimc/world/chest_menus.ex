defmodule Valimc.World.ChestMenus do
  @moduledoc """
  A joined chest inside one group (VMC-032b). Each half keeps its own 27-slot
  entry and revision; the menu concatenates them in vanilla's order. Plans
  replace both entries before returning any resource to the group, whose
  existing frame commits them together with the hosted player's inventory.
  A section outside the group is never read as authority.
  """
  alias Valimc.Blocks.Chest
  alias Valimc.Data.Grid
  alias Valimc.Menus.MenuAccess
  alias Valimc.World.{Blocks, ContainerClicks, Containers, ContainerViewers, RegionData}

  def handle(sections, key, {:menu, epoch, viewer, position, grant}) when is_map(grant) do
    with {:ok, positions} <- joined(sections, key, epoch, position) do
      menu(sections, key, viewer, position, positions, grant)
    end
  end

  def handle(sections, key, {:container_click, epoch, viewer, ref, position, actor, click}) do
    with {:ok, positions} <- joined(sections, key, epoch, position) do
      click(sections, viewer, ref, position, positions, actor, click)
    end
  end

  def handle(_, _, _), do: :pass

  defp joined(sections, key, epoch, position) do
    resource = sections[key]

    if resource.epoch == epoch and RegionData.valid_block_query?([position], :any) and
         section(position) == key do
      block = Blocks.get(resource.blocks, position)

      if Chest.ordinary?(block) and not Chest.single?(block) do
        other = Chest.connected_position(block, position)
        positions = Chest.positions(block, position, &block(sections, &1))

        cond do
          not readable?(sections, other) ->
            {:reply, Valimc.Data.Error.retry(:chest_owner_pending), sections}

          length(positions) == 2 ->
            {:ok, positions}

          true ->
            :pass
        end
      else
        :pass
      end
    else
      :pass
    end
  end

  defp menu(sections, key, viewer, position, positions, grant) do
    block = block(sections, position)
    now = System.monotonic_time(:millisecond)

    with :ok <- available(sections, positions),
         provisional = %{rows: 6, slots: Tuple.duplicate(nil, 54), revision: nil},
         decision <-
           MenuAccess.authorize(
             :chest,
             block,
             provisional,
             above(sections, positions),
             position,
             grant,
             now
           ),
         true <- (is_tuple(decision) and elem(decision, 0) == :chest) or decision == :valid,
         true <-
           grant.kind == :open or
             Enum.all?(positions, fn at ->
               MenuAccess.valid_view?(:chest, block(sections, at), grant.mode, grant.eye, at)
             end) or {:error, :invalid_menu_context} do
      unpack = grant.kind == :open and grant.mode != :spectator

      prepared =
        Enum.reduce(positions, sections, fn at, acc ->
          Map.update!(acc, section(at), &RegionData.prepare_chest(&1, at, unpack))
        end)

      with {:ok, entry} <- entry(prepared, positions),
           decision <-
             MenuAccess.authorize(
               :chest,
               block,
               entry,
               above(prepared, positions),
               position,
               grant,
               now
             ),
           {:ok, next} <- subscribe(prepared, key, viewer, position, positions, grant, decision) do
        {:reply, decision, next}
      else
        {:error, _} = error -> {:reply, error, sections}
      end
    else
      false -> {:reply, decision(sections, position, positions, grant, now), sections}
      {:error, _} = error -> {:reply, error, sections}
    end
  end

  defp decision(sections, position, positions, grant, now) do
    entry = %{rows: 6, slots: Tuple.duplicate(nil, 54), revision: nil}

    MenuAccess.authorize(
      :chest,
      block(sections, position),
      entry,
      above(sections, positions),
      position,
      grant,
      now
    )
  end

  defp subscribe(sections, key, viewer, position, positions, grant, decision) do
    if grant[:menu] == :chest and
         (decision == :valid or match?({:chest, _, _}, decision)) do
      origin = {self(), sections[key].epoch}
      ref = grant[:view_ref]

      with :ok <- preflight(sections, viewer, ref, position, positions, grant, origin) do
        Enum.reduce_while(Enum.group_by(positions, &section/1), {:ok, sections}, fn {part, local},
                                                                                    {:ok, acc} ->
          resource = acc[part]
          view = resource.container_viewers.views[viewer]
          revisions = Map.new(local, &{&1, resource.containers.entries[&1].revision})
          opener = grant.mode != :spectator

          result =
            cond do
              grant.kind == :subscribe and is_reference(ref) ->
                monitor =
                  if view && view.ref == ref, do: view.monitor, else: Process.monitor(viewer)

                case ContainerViewers.register(
                       resource.container_viewers,
                       viewer,
                       ref,
                       monitor,
                       position,
                       opener,
                       revisions,
                       origin
                     ) do
                  {:ok, _, _, _} = result ->
                    {:ok, RegionData.apply_container_viewers(resource, result_viewers(result))}

                  error ->
                    if view == nil or view.monitor != monitor,
                      do: Process.demonitor(monitor, [:flush])

                    error
                end

              view != nil and view.ref == ref and view.position == position and
                  view.opener == opener ->
                {:ok,
                 %{
                   resource
                   | container_viewers:
                       ContainerViewers.observed(
                         resource.container_viewers,
                         viewer,
                         ref,
                         revisions
                       )
                 }}

              true ->
                {:error, :stale_container_view}
            end

          case result do
            {:ok, resource} -> {:cont, {:ok, Map.put(acc, part, resource)}}
            error -> {:halt, error}
          end
        end)
      end
    else
      {:ok, sections}
    end
  end

  defp preflight(sections, viewer, ref, position, positions, grant, origin) do
    if grant.kind == :subscribe do
      Enum.reduce_while(Enum.group_by(positions, &section/1), :ok, fn {part, local}, :ok ->
        resource = sections[part]
        view = resource.container_viewers.views[viewer]
        monitor = if view && view.ref == ref, do: view.monitor, else: make_ref()
        revisions = Map.new(local, &{&1, resource.containers.entries[&1].revision})

        case ContainerViewers.register(
               resource.container_viewers,
               viewer,
               ref,
               monitor,
               position,
               grant.mode != :spectator,
               revisions,
               origin
             ) do
          {:ok, _, _, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  defp result_viewers({:ok, viewers, retired, lids}), do: {viewers, retired, lids}

  defp click(sections, viewer, ref, position, positions, actor, click) do
    now = System.monotonic_time(:millisecond)

    with :ok <- available(sections, positions),
         :ok <-
           MenuAccess.authorize_action(:chest, block(sections, position), position, actor, now),
         true <-
           Enum.all?(positions, fn at ->
             view = sections[section(at)].container_viewers.views[viewer]

             view != nil and view.ref == ref and view.position == position and
               MenuAccess.valid_view?(:chest, block(sections, at), actor.mode, actor.eye, at)
           end) or {:error, :stale_container_view},
         {:ok, entry} <- entry(sections, positions),
         {:ok, slots, inventory, drops} <-
           ContainerClicks.plan(
             entry,
             click.inventory,
             click.action,
             click.slot,
             click.button,
             Map.get(click, :drops, false)
           ),
         {:ok, next} <- replace(sections, positions, slots),
         {:ok, entry} <- entry(next, positions) do
      next =
        Enum.reduce(Enum.uniq(Enum.map(positions, &section/1)), next, fn part, acc ->
          resource = acc[part]
          revisions = Map.take(entry.revision, Enum.filter(positions, &(section(&1) == part)))

          resource = %{
            resource
            | container_viewers:
                ContainerViewers.observed(resource.container_viewers, viewer, ref, revisions)
          }

          resource =
            Enum.reduce(
              Enum.filter(positions, &(section(&1) == part)),
              resource,
              &RegionData.notify_container_changed(&2, &1)
            )

          Map.put(acc, part, resource)
        end)

      {:reply, {:ok, inventory, entry, [], drops}, next}
    else
      {:error, _} = error -> {:reply, error, sections}
    end
  end

  defp replace(sections, positions, slots) do
    positions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, sections}, fn {at, index}, {:ok, acc} ->
      key = section(at)
      resource = acc[key]
      entry = resource.containers.entries[at]
      half = slots |> Tuple.to_list() |> Enum.slice(index * 27, 27) |> List.to_tuple()

      if half == entry.slots do
        {:cont, {:ok, acc}}
      else
        case Containers.replace(resource.containers, at, entry.revision, half) do
          {:ok, containers, _} ->
            {:cont, {:ok, Map.put(acc, key, %{resource | containers: containers})}}

          error ->
            {:halt, error}
        end
      end
    end)
  end

  defp entry(sections, positions) do
    with {:ok, entry} <-
           Containers.chest_view(positions, &sections[section(&1)].containers.entries[&1]) do
      {:ok,
       Map.put(
         entry,
         :owners,
         Enum.map(positions, &{self(), sections[section(&1)].epoch}) |> Enum.uniq()
       )}
    end
  end

  defp available(sections, positions) do
    if Enum.all?(positions, fn at ->
         resource = sections[section(at)]

         resource != nil and RegionData.write_busy(resource) == nil and
           not MapSet.member?(
             resource.generation.absent,
             Grid.chunk_key(elem(at, 0), elem(at, 2))
           )
       end), do: :ok, else: Valimc.Data.Error.retry(:chest_busy)
  end

  defp above(sections, positions) do
    Enum.find_value(positions, 0, fn {x, y, z} ->
      above = block(sections, {x, y + 1, z})
      if MenuAccess.obstructed?(above, false), do: above
    end)
  end

  defp block(sections, position) do
    case sections[section(position)] do
      nil -> nil
      resource -> Blocks.get(resource.blocks, position)
    end
  end

  defp readable?(sections, {x, _, z} = at) do
    case sections[section(at)] do
      nil -> false
      resource -> not MapSet.member?(resource.generation.absent, Grid.chunk_key(x, z))
    end
  end

  defp section({x, _, z}), do: Grid.region_key(Grid.chunk_key(x, z))
end
