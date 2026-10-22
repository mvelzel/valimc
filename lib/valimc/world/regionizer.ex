defmodule Valimc.World.Regionizer do
  @moduledoc """
  Which sections share a group process (VMC-077j2): one regionizer per
  dimension applies Folia's rule at section size 8 × 8 (Folia's grid
  exponent 3, create radius 1, merge radius 1). A loaded section joins every
  group that has a loaded section within #{3} sections of it, so separate
  groups keep their loaded chunks at least 25 chunks apart and nothing that
  can interact ever sits in two groups. A group whose sections fall into
  pieces farther apart than that splits once at least 1/6 of the sections it
  had at its last recalculation have unloaded (Folia's dead-section ratio).

  The regionizer only decides; groups move sections with `Region.hand_over/3`
  and `Region.split/3`, each at its own tick boundary (a group finishes the
  tick it is running first), one change at a time. Groups report sections
  they load and unload; the regionizer watches them and forgets the sections
  of one that stops. Sections merge only within one world folder and tick
  mode (tests run worlds side by side).

  It alone retires groups (VMC-077y, `retire/1`): only one its record holds
  no section of, forgotten first, so a retiring group is never a target.
  """
  alias Valimc.Data.Grid
  use GenServer
  require Logger
  alias Valimc.World.Region

  @reach 3
  @dead_ratio 6

  def start_link(dimension),
    do: GenServer.start_link(__MODULE__, dimension, name: name(dimension))

  def child_spec(dimension),
    do: %{id: {__MODULE__, dimension}, start: {__MODULE__, :start_link, [dimension]}}

  defp name(dimension), do: {:via, Registry, {Valimc.Regionizers, dimension}}

  @doc "Group `pid` loaded section `key` (`{sx, sz}`) of `dimension`."
  def loaded(dimension, key, pid), do: cast(dimension, {:loaded, key, pid, compatibility(key)})

  @doc """
  Group `pid` adopted section `key` of `dimension` from another group: the
  section is its from now on, whatever earlier reports said.
  """
  def adopted(dimension, key, pid), do: cast(dimension, {:adopted, key, pid, compatibility(key)})

  @doc "Group `pid` unloaded section `key` (`{sx, sz}`) of `dimension`."
  def unloaded(dimension, key, pid), do: cast(dimension, {:unloaded, key, pid})

  @doc "The calling group has nothing left: `:ok` (it stops on `:retire`), or `:none`."
  def retire(dimension) do
    case GenServer.whereis(name(dimension)) do
      nil -> :none
      pid -> GenServer.cast(pid, {:retire, self()})
    end
  end

  @doc "The groups of `dimension`: `%{pid => [{sx, sz}]}` (tests, measurements)."
  def groups(dimension), do: GenServer.call(name(dimension), :groups, 30_000)

  @doc """
  `:ok` once every load and unload of `dimension` reported before this call
  is handled: its merges and splits are made and their routes moved. A
  section's load is reported before `World.owner/1` first answers for it.
  """
  def settle(dimension), do: GenServer.call(name(dimension), :settle, 30_000)

  defp cast(dimension, message) do
    GenServer.cast(name(dimension), message)
  catch
    :exit, _ -> :ok
  end

  # Sections of different worlds or tick modes never share a group.
  defp compatibility(key),
    do: {Valimc.config(:world_path, key), Valimc.config(:region_ticks, key)}

  @impl true
  def init(dimension) do
    state = %{
      dimension: dimension,
      # key => {pid, compatibility}
      sections: %{},
      # pid => %{keys: MapSet, monitor: ref, since: sections at last recalculation, gone: unloaded since}
      groups: %{}
    }

    {:ok, rebuild(state)}
  end

  # After a restart: the sections the Directory routes in this dimension.
  defp rebuild(state) do
    rows =
      try do
        :ets.tab2list(Valimc.RegionRoutes)
      rescue
        ArgumentError -> []
      end

    for {scoped, pid, _, _, %{}} <- rows,
        {dimension, key} = Grid.split_section(scoped),
        dimension == state.dimension,
        Valimc.config(:regionizer, key),
        reduce: state do
      acc -> add(acc, key, pid, compatibility(key))
    end
  end

  @impl true
  def handle_call(:settle, _from, state), do: {:reply, :ok, state}

  def handle_call(:groups, _from, state),
    do: {:reply, Map.new(state.groups, fn {pid, g} -> {pid, Enum.sort(g.keys)} end), state}

  @impl true
  # A section that unloaded before its load report is read merges nothing:
  # groups never join through a section that is gone (its unload report,
  # still on its way, takes it off again).
  def handle_cast({:loaded, key, pid, compat}, state) do
    state = add(state, key, pid, compat)
    if routed?(state, key), do: {:noreply, merge_around(state, key)}, else: {:noreply, state}
  end

  def handle_cast({:adopted, key, pid, compat}, state),
    do: {:noreply, add(state, key, pid, compat)}

  def handle_cast({:unloaded, key, pid}, state) do
    case state.sections do
      %{^key => {^pid, _}} -> {:noreply, state |> remove(key, pid) |> maybe_split(pid)}
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:retire, pid}, state) do
    group = state.groups[pid]

    if group && MapSet.size(group.keys) > 0 do
      {:noreply, state}
    else
      if group, do: Process.demonitor(group.monitor, [:flush])
      send(pid, :retire)
      {:noreply, %{state | groups: Map.delete(state.groups, pid)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.groups, pid) do
      {nil, _} ->
        {:noreply, state}

      {group, groups} ->
        {:noreply,
         %{state | groups: groups, sections: Map.drop(state.sections, MapSet.to_list(group.keys))}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  # A section a report puts in `pid`'s group leaves the group it was in.
  defp add(state, key, pid, compat) do
    state =
      case state.sections do
        %{^key => {^pid, _}} -> state
        %{^key => {other, _}} -> leave(state, key, other)
        _ -> state
      end

    state =
      case state.groups do
        %{^pid => _} ->
          state

        _ ->
          group = %{keys: MapSet.new(), monitor: Process.monitor(pid), since: 0, gone: 0}
          %{state | groups: Map.put(state.groups, pid, group)}
      end

    group = state.groups[pid]
    keys = MapSet.put(group.keys, key)

    %{
      state
      | sections: Map.put(state.sections, key, {pid, compat}),
        groups:
          Map.put(state.groups, pid, %{
            group
            | keys: keys,
              since: max(group.since, MapSet.size(keys))
          })
    }
  end

  defp remove(state, key, pid) do
    group = state.groups[pid]

    %{
      state
      | sections: Map.delete(state.sections, key),
        groups:
          Map.put(state.groups, pid, %{
            group
            | keys: MapSet.delete(group.keys, key),
              gone: group.gone + 1
          })
    }
  end

  defp near({x, z}, r),
    do: for(dx <- -r..r, dz <- -r..r, {dx, dz} != {0, 0}, do: {x + dx, z + dz})

  # Merge every compatible group with a section within reach into the largest.
  defp merge_around(state, key) do
    {pid, compat} = state.sections[key]

    pids =
      for k <- near(key, @reach),
          {p, ^compat} <- [state.sections[k]],
          uniq: true,
          do: p

    case Enum.uniq(pids ++ [pid]) do
      [_] -> state
      pids -> merge(state, pids)
    end
  end

  # Into the largest group; on a tie the one that was there first, so a
  # group's route (its log stripe) stays put while sections join it.
  # A section a source no longer held unloaded since its report: it counts as
  # gone from the merged group, which then splits if it fell apart.
  defp merge(state, pids) do
    target = Enum.max_by(pids, &MapSet.size(state.groups[&1].keys))
    t = state.groups[target]
    state = %{state | groups: Map.put(state.groups, target, %{t | gone: 0})}

    Enum.reduce(pids -- [target], state, fn source, acc ->
      started = System.monotonic_time(:microsecond)
      known = acc.groups[source].keys

      case safe_hand_over(source, target, :all) do
        {:ok, moved} ->
          Valimc.Data.Metrics.add(:regionizer_merges)

          Valimc.Data.Metrics.add(
            :regionizer_merge_microseconds,
            System.monotonic_time(:microsecond) - started
          )

          acc
          |> transfer(target, moved)
          |> lost(target, MapSet.to_list(MapSet.difference(known, MapSet.new(moved))))

        {:error, reason} ->
          Logger.debug(
            "Merging group #{inspect(source)} into #{inspect(target)}: #{inspect(reason)}"
          )

          acc
      end
    end)
    |> then(fn acc -> if acc.groups[target].gone > 0, do: maybe_split(acc, target), else: acc end)
  end

  # The sections `source` handed over are `target`'s (`lost/3` takes those it
  # no longer held).
  defp transfer(state, target, moved) do
    state =
      Enum.reduce(moved, state, fn key, acc ->
        case acc.sections do
          %{^key => {_, compat}} -> add(acc, key, target, compat)
          _ -> acc
        end
      end)

    t = state.groups[target]
    %{state | groups: Map.put(state.groups, target, %{t | since: MapSet.size(t.keys)})}
  end

  defp lost(state, _target, []), do: state

  defp lost(state, target, keys) do
    state =
      Enum.reduce(keys, state, fn key, acc ->
        case acc.sections do
          %{^key => {pid, _}} ->
            leave(%{acc | sections: Map.delete(acc.sections, key)}, key, pid)

          _ ->
            acc
        end
      end)

    t = state.groups[target]
    %{state | groups: Map.put(state.groups, target, %{t | gone: t.gone + length(keys)})}
  end

  # Whether `key` still has a route: it is loaded.
  defp routed?(state, {sx, sz}) do
    :ets.member(Valimc.RegionRoutes, {state.dimension, sx, sz})
  rescue
    ArgumentError -> false
  end

  # `key` is no longer in `pid`'s group; a group left with none is forgotten.
  defp leave(state, key, pid) do
    case state.groups do
      %{^pid => group} ->
        keys = MapSet.delete(group.keys, key)

        if MapSet.size(keys) == 0 do
          Process.demonitor(group.monitor, [:flush])
          %{state | groups: Map.delete(state.groups, pid)}
        else
          %{state | groups: Map.put(state.groups, pid, %{group | keys: keys})}
        end

      _ ->
        state
    end
  end

  defp safe_hand_over(source, target, keys) do
    Region.hand_over(source, target, keys)
  catch
    :exit, reason -> {:error, reason}
  end

  # Split a group whose sections fall into pieces beyond reach, once enough of
  # its sections have unloaded since it last changed (Folia's 1/6).
  defp maybe_split(state, pid) do
    group = state.groups[pid]

    cond do
      MapSet.size(group.keys) == 0 ->
        state

      group.gone * @dead_ratio < max(group.since, 1) ->
        state

      true ->
        case pieces(group.keys) do
          [_] ->
            %{
              state
              | groups:
                  Map.put(state.groups, pid, %{group | since: MapSet.size(group.keys), gone: 0})
            }

          pieces ->
            split(state, pid, pieces)
        end
    end
  end

  # Connected pieces under the merge reach, largest first.
  defp pieces(keys) do
    keys
    |> Enum.reduce({MapSet.new(), []}, fn key, {seen, acc} ->
      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        piece = flood(keys, [key], MapSet.new([key]))
        {MapSet.union(seen, piece), [piece | acc]}
      end
    end)
    |> elem(1)
    |> Enum.sort_by(&(-MapSet.size(&1)))
  end

  defp flood(_keys, [], piece), do: piece

  defp flood(keys, [key | rest], piece) do
    next =
      for k <- near(key, @reach), MapSet.member?(keys, k), not MapSet.member?(piece, k), do: k

    flood(keys, next ++ rest, Enum.into(next, piece))
  end

  defp split(state, pid, [_kept | others]) do
    Enum.reduce(others, state, fn piece, acc ->
      started = System.monotonic_time(:microsecond)
      keys = MapSet.to_list(piece)

      case safe_split(acc.dimension, pid, keys) do
        {:ok, nil, []} ->
          acc

        {:ok, new, moved} ->
          Valimc.Data.Metrics.add(:regionizer_splits)

          Valimc.Data.Metrics.add(
            :regionizer_split_microseconds,
            System.monotonic_time(:microsecond) - started
          )

          Enum.reduce(moved, acc, fn k, a -> add(a, k, new, elem(a.sections[k], 1)) end)

        {:error, reason} ->
          Logger.debug("Splitting group #{inspect(pid)}: #{inspect(reason)}")
          acc
      end
    end)
    |> then(fn acc ->
      case acc.groups do
        %{^pid => group} ->
          %{
            acc
            | groups: Map.put(acc.groups, pid, %{group | since: MapSet.size(group.keys), gone: 0})
          }

        _ ->
          acc
      end
    end)
  end

  defp safe_split(dimension, pid, keys) do
    Region.split(pid, dimension, keys)
  catch
    :exit, reason -> {:error, reason}
  end
end
