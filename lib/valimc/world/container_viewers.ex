defmodule Valimc.World.ContainerViewers do
  @moduledoc "Region-local bounded observations; session refs fence retirement and one pending notice coalesces revisions."
  defstruct views: %{}, positions: %{}
  @max_views 1024
  @max_revision 18_446_744_073_709_551_615
  def max_views, do: @max_views

  def register(%__MODULE__{} = state, pid, ref, monitor, {x, y, z} = position, opener, revision)
      when is_pid(pid) and is_reference(ref) and is_reference(monitor) and is_integer(x) and
             is_integer(y) and is_integer(z) and is_boolean(opener) and
             is_integer(revision) and revision in 1..@max_revision do
    old = state.views[pid]

    cond do
      not Valimc.World.Chunk.valid_y?(y) or abs(x) > 29_999_984 or abs(z) > 29_999_984 ->
        {:error, :invalid_container_view}

      old == nil and map_size(state.views) >= @max_views ->
        {:error, :container_viewer_limit}

      old != nil and old.ref == ref ->
        if old.position == position and old.opener == opener and old.monitor == monitor,
          do: {:ok, state, [], []},
          else: {:error, :container_view_reference_conflict}

      true ->
        {next, retired} = drop(state, pid)
        {members, count} = Map.get(next.positions, position, {MapSet.new(), 0})

        view = %{
          pid: pid,
          ref: ref,
          monitor: monitor,
          position: position,
          opener: opener,
          revision: revision,
          pending: false
        }

        next = %{
          next
          | views: Map.put(next.views, pid, view),
            positions:
              Map.put(next.positions, position, {MapSet.put(members, pid), count + bit(opener)})
        }

        touched = if old, do: [old.position, position], else: [position]
        {:ok, next, retired, lids(state, next, touched)}
    end
  end

  def register(_, _, _, _, _, _, _), do: {:error, :invalid_container_view}

  @doc "The views' section moved to another group process (VMC-077j): watch the viewers from it."
  def remonitor(%__MODULE__{} = state),
    do: %{
      state
      | views:
          Map.new(state.views, fn {pid, v} -> {pid, %{v | monitor: Process.monitor(pid)}} end)
    }

  def unregister(%__MODULE__{} = state, pid, ref) do
    case state.views[pid] do
      %{ref: ^ref, position: position} ->
        {next, retired} = drop(state, pid)
        {next, retired, lids(state, next, [position])}

      _ ->
        {state, [], []}
    end
  end

  def down(%__MODULE__{} = state, pid, monitor) do
    case state.views[pid] do
      %{monitor: ^monitor, ref: ref} -> unregister(state, pid, ref)
      _ -> {state, [], []}
    end
  end

  def invalidate(%__MODULE__{} = state, positions) do
    {next, retired} =
      Enum.reduce(Enum.uniq(positions), {state, []}, fn position, {current, retired} ->
        {members, _} = Map.get(current.positions, position, {MapSet.new(), 0})

        Enum.reduce(members, {current, retired}, fn pid, {current, retired} ->
          {current, removed} = drop(current, pid)
          {current, removed ++ retired}
        end)
      end)

    {next, retired, lids(state, next, positions)}
  end

  def changed(%__MODULE__{} = state, position, revision)
      when is_integer(revision) and revision in 1..@max_revision do
    {members, _} = Map.get(state.positions, position, {MapSet.new(), 0})

    Enum.reduce(members, {state, []}, fn pid, {current, notices} ->
      view = current.views[pid]

      if revision > view.revision do
        notices = if view.pending, do: notices, else: [{pid, view.ref, revision} | notices]
        view = %{view | pending: true, revision: revision}
        {%{current | views: Map.put(current.views, pid, view)}, notices}
      else
        {current, notices}
      end
    end)
  end

  def changed(state, _, _), do: {state, []}

  @doc "Coalesce owned timer observations independently of item-content revisions."
  def progressed(%__MODULE__{} = state, position, generation)
      when is_integer(generation) and generation in 1..@max_revision do
    {members, _} = Map.get(state.positions, position, {MapSet.new(), 0})

    Enum.reduce(members, {state, []}, fn pid, {current, notices} ->
      view = current.views[pid]

      if generation > Map.get(view, :progress, 0) do
        notices =
          if Map.get(view, :progress_pending, false),
            do: notices,
            else: [{pid, view.ref, generation} | notices]

        view = Map.merge(view, %{progress: generation, progress_pending: true})
        {%{current | views: Map.put(current.views, pid, view)}, notices}
      else
        {current, notices}
      end
    end)
  end

  def progressed(state, _, _), do: {state, []}

  def observed_progress(%__MODULE__{} = state, pid, ref, generation)
      when is_integer(generation) and generation in 0..@max_revision do
    case state.views[pid] do
      %{ref: ^ref} = view ->
        if generation >= Map.get(view, :progress, 0) do
          view = Map.merge(view, %{progress: generation, progress_pending: false})
          %{state | views: Map.put(state.views, pid, view)}
        else
          state
        end

      _ ->
        state
    end
  end

  def observed_progress(state, _, _, _), do: state

  def observed(%__MODULE__{} = state, pid, ref, revision)
      when is_integer(revision) and revision in 1..@max_revision do
    case state.views[pid] do
      %{ref: ^ref, revision: latest} = view when revision >= latest ->
        %{state | views: Map.put(state.views, pid, %{view | revision: revision, pending: false})}

      _ ->
        state
    end
  end

  def observed(state, _, _, _), do: state

  def open_count(%__MODULE__{} = state, position),
    do: state.positions |> Map.get(position, {nil, 0}) |> elem(1)

  defp drop(state, pid) do
    case Map.pop(state.views, pid) do
      {nil, _} ->
        {state, []}

      {view, views} ->
        {members, count} = Map.fetch!(state.positions, view.position)
        members = MapSet.delete(members, pid)

        positions =
          if MapSet.size(members) == 0,
            do: Map.delete(state.positions, view.position),
            else: Map.put(state.positions, view.position, {members, count - bit(view.opener)})

        {%{state | views: views, positions: positions}, [view]}
    end
  end

  defp lids(before, after_state, positions) do
    positions
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn position ->
      was = open_count(before, position) > 0
      now = open_count(after_state, position) > 0
      if was != now, do: [{position, now}], else: []
    end)
  end

  defp bit(true), do: 1
  defp bit(false), do: 0
end
