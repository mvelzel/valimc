defmodule Valimc.World.ContainerViewers do
  @moduledoc "Region-local bounded observations; session refs fence retirement and one pending notice coalesces revisions."
  defstruct views: %{}, positions: %{}
  @max_views 1024
  @max_revision 18_446_744_073_709_551_615
  def max_views, do: @max_views

  def register(state, pid, ref, monitor, position, opener, revision, origin \\ nil)

  def register(
        %__MODULE__{} = state,
        pid,
        ref,
        monitor,
        {x, y, z} = position,
        opener,
        revision,
        origin
      )
      when is_pid(pid) and is_reference(ref) and is_reference(monitor) and is_integer(x) and
             is_integer(y) and is_integer(z) and is_boolean(opener) and
             (is_integer(revision) or is_map(revision)) do
    old = state.views[pid]

    cond do
      not valid_revision?(revision) or not Valimc.World.Chunk.valid_y?(y) or
        abs(x) > 29_999_984 or abs(z) > 29_999_984 ->
        {:error, :invalid_container_view}

      old == nil and map_size(state.views) >= @max_views ->
        {:error, :container_viewer_limit}

      old != nil and old.ref == ref ->
        if old.position == position and old.opener == opener and old.monitor == monitor and
             positions(old) == positions(%{position: position, revision: revision}),
           do: {:ok, state, [], []},
           else: {:error, :container_view_reference_conflict}

      true ->
        {next, retired} = drop(state, pid)

        view = %{
          pid: pid,
          ref: ref,
          monitor: monitor,
          position: position,
          opener: opener,
          revision: revision,
          pending: false,
          origin: origin
        }

        next = %{
          next
          | views: Map.put(next.views, pid, view),
            positions:
              Enum.reduce(positions(view), next.positions, fn at, index ->
                {members, count} = Map.get(index, at, {MapSet.new(), 0})
                Map.put(index, at, {MapSet.put(members, pid), count + bit(opener)})
              end)
        }

        touched = if old, do: positions(old) ++ positions(view), else: positions(view)
        {:ok, next, retired, lids(state, next, touched)}
    end
  end

  def register(_, _, _, _, _, _, _, _), do: {:error, :invalid_container_view}

  @doc "The views' section moved to another group process (VMC-077j): watch the viewers from it."
  def remonitor(%__MODULE__{} = state),
    do: %{
      state
      | views:
          Map.new(state.views, fn {pid, v} -> {pid, %{v | monitor: Process.monitor(pid)}} end)
    }

  def unregister(%__MODULE__{} = state, pid, ref) do
    case state.views[pid] do
      %{ref: ^ref} = view ->
        {next, retired} = drop(state, pid)
        {next, retired, lids(state, next, positions(view))}

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

    touched = positions ++ Enum.flat_map(retired, &positions/1)
    {next, retired, lids(state, next, touched)}
  end

  def changed(%__MODULE__{} = state, position, revision)
      when is_integer(revision) and revision in 1..@max_revision do
    {members, _} = Map.get(state.positions, position, {MapSet.new(), 0})

    Enum.reduce(members, {state, []}, fn pid, {current, notices} ->
      view = current.views[pid]

      previous = if is_map(view.revision), do: view.revision[position], else: view.revision

      if revision > previous do
        notices = if view.pending, do: notices, else: [{pid, view.ref, revision} | notices]

        seen =
          if is_map(view.revision), do: Map.put(view.revision, position, revision), else: revision

        view = %{view | pending: true, revision: seen}
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
      when is_integer(revision) or is_map(revision) do
    case state.views[pid] do
      %{ref: ^ref} = view ->
        if valid_revision?(revision) and observed?(revision, view.revision),
          do: %{
            state
            | views: Map.put(state.views, pid, %{view | revision: revision, pending: false})
          },
          else: state

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
        positions =
          Enum.reduce(positions(view), state.positions, fn at, index ->
            {members, count} = Map.fetch!(index, at)
            members = MapSet.delete(members, pid)

            if MapSet.size(members) == 0,
              do: Map.delete(index, at),
              else: Map.put(index, at, {members, count - bit(view.opener)})
          end)

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

  defp positions(%{revision: revisions}) when is_map(revisions),
    do: Enum.sort(Map.keys(revisions))

  defp positions(view), do: [view.position]

  defp valid_revision?(revision) when is_integer(revision), do: revision in 1..@max_revision

  defp valid_revision?(revisions) when is_map(revisions) and map_size(revisions) in 1..2,
    do:
      Enum.all?(revisions, fn
        {{x, y, z}, revision} ->
          is_integer(x) and is_integer(z) and abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and
            Valimc.World.Chunk.valid_y?(y) and valid_revision?(revision)

        _ ->
          false
      end)

  defp valid_revision?(_), do: false

  defp observed?(revisions, previous) when is_map(revisions) and is_map(previous),
    do:
      MapSet.new(Map.keys(revisions)) == MapSet.new(Map.keys(previous)) and
        Enum.all?(previous, fn {at, revision} -> revisions[at] >= revision end)

  defp observed?(revision, previous) when is_integer(revision) and is_integer(previous),
    do: revision >= previous

  defp observed?(_, _), do: false

  defp bit(true), do: 1
  defp bit(false), do: 0
end
