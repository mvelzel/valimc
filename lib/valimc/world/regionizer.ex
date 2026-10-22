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
  """
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

  @doc "Group `pid` unloaded section `key` (`{sx, sz}`) of `dimension`."
  def unloaded(dimension, key, pid), do: cast(dimension, {:unloaded, key, pid})

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
        {dimension, key} = Valimc.World.split_section(scoped),
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
  def handle_cast({:loaded, key, pid, compat}, state) do
    state = add(state, key, pid, compat)
    {:noreply, merge_around(state, key)}
  end

  def handle_cast({:unloaded, key, pid}, state) do
    case state.sections do
      %{^key => {^pid, _}} -> {:noreply, state |> remove(key, pid) |> maybe_split(pid)}
      _ -> {:noreply, state}
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

  defp add(state, key, pid, compat) do
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
  defp merge(state, pids) do
    target = Enum.max_by(pids, &MapSet.size(state.groups[&1].keys))

    Enum.reduce(pids -- [target], state, fn source, acc ->
      started = System.monotonic_time(:microsecond)

      case safe_hand_over(source, target, :all) do
        :ok ->
          Valimc.Metrics.add(:regionizer_merges)

          Valimc.Metrics.add(
            :regionizer_merge_microseconds,
            System.monotonic_time(:microsecond) - started
          )

          move_all(acc, source, target)

        {:error, reason} ->
          Logger.debug(
            "Merging group #{inspect(source)} into #{inspect(target)}: #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  defp move_all(state, source, target) do
    {%{keys: keys, monitor: monitor}, groups} = Map.pop(state.groups, source)
    Process.demonitor(monitor, [:flush])

    sections =
      Enum.reduce(keys, state.sections, fn key, acc ->
        Map.update!(acc, key, fn {_, compat} -> {target, compat} end)
      end)

    t = groups[target]
    t = %{t | keys: MapSet.union(t.keys, keys)}
    t = %{t | since: MapSet.size(t.keys), gone: 0}
    %{state | sections: sections, groups: Map.put(groups, target, t)}
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
        {:ok, new} ->
          Valimc.Metrics.add(:regionizer_splits)

          Valimc.Metrics.add(
            :regionizer_split_microseconds,
            System.monotonic_time(:microsecond) - started
          )

          group = acc.groups[pid]

          acc = %{
            acc
            | groups:
                Map.put(acc.groups, pid, %{group | keys: MapSet.difference(group.keys, piece)})
          }

          compats = Map.new(keys, &{&1, elem(acc.sections[&1], 1)})
          acc = Enum.reduce(keys, acc, fn k, a -> add(a, k, new, compats[k]) end)
          acc

        {:error, reason} ->
          Logger.debug("Splitting group #{inspect(pid)}: #{inspect(reason)}")
          acc
      end
    end)
    |> then(fn acc ->
      group = acc.groups[pid]

      %{
        acc
        | groups: Map.put(acc.groups, pid, %{group | since: MapSet.size(group.keys), gone: 0})
      }
    end)
  end

  defp safe_split(dimension, pid, keys) do
    Region.split(pid, dimension, keys)
  catch
    :exit, reason -> {:error, reason}
  end
end
