defmodule Valimc.AI.Behaviors.Poi do
  @moduledoc """
  The point-of-interest behaviours of the village family (VMC-044a1), as
  vanilla's `ai.behavior` classes build them: claiming a POI the mob can
  path to (`AcquirePoi`), forgetting one gone or taken (`ValidateNearbyPoi`),
  walking to a remembered POI (`SetWalkTargetFromBlockMemory`) and strolling
  near one (`StrollAroundPoi`, `StrollToPoi`, `StrollToPoiList`), and the
  village-bound walks (`VillageBoundRandomStroll`, `GoToClosestVillage`,
  `SetClosestHomeAsWalkTarget`).

  A POI memory is `{dimension, {x, y, z}}` (vanilla's `GlobalPos`).
  `release/2` gives a memory's ticket back as `Villager.releasePoi` does:
  the world's claims are the villagers' memories, so erasing the memory is
  the release.
  """
  alias Valimc.AI.{Behavior, Behaviors, Brain, Navigation, Pois, RandomPos, Self, World}
  alias Valimc.Data.Float32

  @doc "A POI memory of the mob's dimension at `pos`."
  def global(%Self{world: world}, pos), do: {world.dimension, pos}

  @doc "The position of a POI memory in the mob's dimension, or nil."
  def here(%Self{world: world} = self, memory) do
    case Brain.get(self, memory) do
      {dimension, pos} when dimension == world.dimension -> pos
      _ -> nil
    end
  end

  @doc "`Villager.releasePoi(memory)`: the claim goes with the memory (the world counts it no more)."
  def release(%Self{} = self, memory) do
    case Brain.get(self, memory) do
      {_, pos} -> self |> Pois.release(pos) |> Brain.erase(memory)
      nil -> self
    end
  end

  # A walk target to a block, as `new WalkTarget(BlockPos, speed, close)`.
  defp walk_block({x, y, z} = block, speed, close),
    do: %{
      target: {:block, block, {x + 0.5, y + 0.5, z + 0.5}},
      speed: Float32.round(speed),
      close: close
    }

  # A walk target to a point (`new WalkTarget(Vec3, ...)`).
  defp walk_point(point, speed, close),
    do: %{target: Behaviors.point(point), speed: Float32.round(speed), close: close}

  defp manhattan({ax, ay, az}, {bx, by, bz}), do: abs(ax - bx) + abs(ay - by) + abs(az - bz)

  ## AcquirePoi

  @doc """
  `AcquirePoi.create(types, validate, acquire, onlyIfAdult, event, valid)`:
  every 20 to 40 ticks, the five nearest POIs of `types` with a ticket
  free (each skipped while its retry marker waits), those `valid.(self,
  pos)` accepts, and a path to any of them: reached, the mob takes the one
  it reaches and remembers it in `acquire` (`event` is the entity event it
  shows). A failed search marks each for a retry later (40 to 80 ticks
  more each time, at most 400). A deferred search's answer comes on a
  later tick; the claim follows then.
  """
  def acquire(types, validate, acquire, opts \\ []) do
    adult = Keyword.get(opts, :adult, false)
    event = Keyword.get(opts, :event)
    valid = Keyword.get(opts, :valid, fn _, _ -> true end)

    conditions =
      if validate == acquire,
        do: [{acquire, :absent}],
        else: [{validate, :absent}, {acquire, :absent}]

    Behavior.one_shot(conditions, %{next: 0, cache: %{}, pending: nil}, fn self, st ->
      types = if is_function(types), do: types.(self), else: types

      cond do
        st.pending != nil ->
          answer(self, st, acquire, event)

        adult and baby?(self) ->
          {false, self, st}

        st.next == 0 ->
          {n, self} = Behavior.level_int(self, 20)
          {false, self, %{st | next: self.world.time + n}}

        self.world.time < st.next ->
          {false, self, st}

        true ->
          scan(self, st, types, acquire, event, valid)
      end
    end)
  end

  defp baby?(%Self{data: %{age: age}}), do: age < 0
  defp baby?(_self), do: false

  defp scan(self, st, types, acquire, event, valid) do
    now = self.world.time
    {n, self} = Behavior.level_int(self, 20)
    st = %{st | next: now + 20 + n}
    cache = for {pos, r} <- st.cache, now - r.previous < 400, into: %{}, do: {pos, r}

    # The retry test runs over every POI in range before the nearest are taken.
    {kept, cache, self} =
      self.world
      |> Pois.in_range(types, Self.block(self), 48, :has_space)
      |> Enum.reduce({[], cache, self}, fn {type, pos}, {kept, cache, self} ->
        case cache do
          %{^pos => r} ->
            if now >= r.next do
              {r, self} = mark(r, now, self)
              {[{type, pos} | kept], Map.put(cache, pos, r), self}
            else
              {kept, cache, self}
            end

          _ ->
            {[{type, pos} | kept], cache, self}
        end
      end)

    center = Self.block(self)

    pois =
      kept
      |> Enum.reverse()
      |> Enum.sort_by(fn {_, pos} -> Pois.dist_sq(pos, center) end)
      |> Enum.take(5)
      |> Enum.filter(fn {_, pos} -> valid.(self, pos) end)

    st = %{st | cache: cache}

    case pois do
      [] ->
        {true, self, st}

      _ ->
        reach = Enum.reduce(pois, 1, fn {type, _}, r -> max(r, Pois.type(type).valid_range) end)
        {path, self} = Navigation.path_to_any(self, Enum.map(pois, &elem(&1, 1)), reach)
        searched(self, st, path, pois, acquire, event)
    end
  end

  # A deferred search: its answer arrives in `world.paths` on a later tick.
  defp searched(self, st, %{pending: n}, pois, _acquire, _event),
    do: {true, self, %{st | pending: {n, pois, self.world.time}}}

  defp searched(self, st, path, pois, acquire, event) do
    if path != nil and path.reached do
      take(self, st, path.target, acquire, event)
    else
      fail(self, st, pois, self.world.time)
    end
  end

  defp answer(self, %{pending: {n, pois, at}} = st, acquire, event) do
    case Map.fetch(self.world.paths, {self.uuid, n}) do
      {:ok, {path, _, _}} when path != nil ->
        st = %{st | pending: nil}

        if path.reached,
          do: take(self, st, path.target, acquire, event),
          else: fail(self, st, pois, at)

      {:ok, _} ->
        fail(self, %{st | pending: nil}, pois, at)

      :error ->
        if self.world.time - at > 40,
          do: {false, self, %{st | pending: nil}},
          else: {false, self, st}
    end
  end

  # `poiManager.take` of the reached POI, if it still is one.
  defp take(self, st, target, acquire, event) do
    case Pois.type_at(self.world, target) do
      nil ->
        {true, self, st}

      _type ->
        self =
          self
          |> Pois.take(target)
          |> Brain.set(acquire, global(self, target))

        self = if event, do: Self.effect(self, {:event, event}), else: self
        {true, self, %{st | cache: %{}}}
    end
  end

  # Each POI tried gets a retry marker (in the set's order).
  defp fail(self, st, pois, now) do
    {cache, self} =
      Enum.reduce(pois, {st.cache, self}, fn {_, pos}, {cache, self} ->
        if Map.has_key?(cache, pos) do
          {cache, self}
        else
          {r, self} = mark(%{previous: 0, next: 0, delay: 0}, now, self)
          {Map.put(cache, pos, r), self}
        end
      end)

    {true, self, %{st | cache: cache}}
  end

  # `JitteredLinearRetry.markAttempt`.
  defp mark(r, now, self) do
    {n, self} = Behavior.level_int(self, 40)
    delay = min(r.delay + n + 40, 400)
    {%{r | previous: now, delay: delay, next: now + delay}, self}
  end

  ## ValidateNearbyPoi

  @doc """
  `ValidateNearbyPoi.create(types, memory)`: within 16 blocks of the
  remembered POI, forget it when it is no longer of `types`, or when it is a
  bed someone else lies in (a villager's bed stays claimed).
  """
  def validate(types, memory) do
    Behavior.one_shot([{memory, :present}], fn self ->
      types = if is_function(types), do: types.(self), else: types

      case Brain.get(self, memory) do
        {dimension, pos} when dimension == self.world.dimension ->
          if Pois.near_center?(pos, {self.x, self.y, self.z}, 16.0) do
            {true, check(self, memory, pos, types)}
          else
            {false, self}
          end

        _ ->
          {false, self}
      end
    end)
  end

  defp check(self, memory, pos, types) do
    type = Pois.type_at(self.world, pos)

    cond do
      type == nil or type not in types ->
        Brain.erase(self, memory)

      occupied_bed?(self, pos) ->
        self = Brain.erase(self, memory)
        if sleeping_villager?(self, pos), do: self, else: Pois.release(self, pos)

      true ->
        self
    end
  end

  defp occupied_bed?(self, pos) do
    state = World.block(self.world, pos)

    state != nil and Valimc.AI.Brains.Villager.sleeps_on?(state) and
      Valimc.AI.Brains.Villager.occupied?(state) and not sleeping?(self)
  end

  defp sleeping?(%Self{data: data}), do: is_map(data) and Map.get(data, :sleeping) != nil

  defp sleeping_villager?(%Self{world: world}, {x, y, z}) do
    Enum.any?(world.mobs, fn m ->
      m.type == "minecraft:villager" and Map.get(m, :sleeping) != nil and
        World.intersects?(World.box(m), {x, y, z, x + 1, y + 1, z + 1})
    end)
  end

  ## Walks to and near POIs

  @doc """
  `SetWalkTargetFromBlockMemory.create(memory, speed, close, tooFar,
  tooLong)`: toward the remembered block (a step toward it when farther than
  `too_far`); forget it when it is in another dimension or unreachable for
  longer than `too_long` ticks, or when no step toward it is found.
  """
  def walk_to_memory(memory, speed, close, too_far, too_long) do
    Behavior.one_shot(
      [cant_reach_walk_target_since: :registered, walk_target: :absent] ++ [{memory, :present}],
      fn self ->
        {dimension, pos} = Brain.get(self, memory)
        since = Brain.get(self, :cant_reach_walk_target_since)
        now = self.world.time

        if dimension == self.world.dimension and (since == nil or now - since <= too_long) do
          distance = manhattan(pos, Self.block(self))

          cond do
            distance > too_far ->
              {true, step_toward(self, memory, pos, speed, close, too_far)}

            distance > close ->
              {true, Brain.set(self, :walk_target, walk_block(pos, speed, close))}

            true ->
              {true, self}
          end
        else
          {true, self |> release(memory) |> Brain.set(:cant_reach_walk_target_since, now)}
        end
      end
    )
  end

  defp step_toward(self, memory, {x, y, z}, speed, close, too_far) do
    towards = {x + 0.5, y * 1.0, z + 0.5}
    radians = Float32.round(:math.pi() / 2)

    Enum.reduce_while(1..1000, self, fn tries, self ->
      case RandomPos.default_towards(self, 15, 7, towards, radians) do
        {nil, self} ->
          if tries == 1000, do: {:halt, give_up(self, memory)}, else: {:cont, self}

        {point, self} ->
          {px, py, pz} = point

          if manhattan({floor(px), floor(py), floor(pz)}, Self.block(self)) > too_far do
            if tries == 1000, do: {:halt, give_up(self, memory)}, else: {:cont, self}
          else
            {:halt, Brain.set(self, :walk_target, walk_point(point, speed, close))}
          end
      end
    end)
  end

  defp give_up(self, memory),
    do: self |> release(memory) |> Brain.set(:cant_reach_walk_target_since, self.world.time)

  @doc """
  `StrollAroundPoi.create(memory, speed, maxDistance)`: within `max` of the
  remembered POI, a land walk target 8 blocks around now and then (180
  ticks apart).
  """
  def stroll_around(memory, speed, max) do
    Behavior.one_shot([walk_target: :registered] ++ [{memory, :present}], 0, fn self, next ->
      case near(self, memory, max) do
        nil ->
          {false, self, next}

        _pos ->
          if self.world.time <= next do
            {true, self, next}
          else
            {pos, self} = RandomPos.land(self, 8, 6)

            self =
              if pos,
                do: Brain.set(self, :walk_target, walk_point(pos, speed, 1)),
                else: Brain.erase(self, :walk_target)

            {true, self, self.world.time + 180}
          end
      end
    end)
  end

  @doc "`StrollToPoi.create(memory, speed, close, maxDistance)`: back to the POI every 80 ticks."
  def stroll_to(memory, speed, close, max) do
    Behavior.one_shot([walk_target: :registered] ++ [{memory, :present}], 0, fn self, next ->
      case near(self, memory, max) do
        nil ->
          {false, self, next}

        pos ->
          if self.world.time <= next,
            do: {true, self, next},
            else:
              {true, Brain.set(self, :walk_target, walk_block(pos, speed, close)),
               self.world.time + 80}
      end
    end)
  end

  @doc """
  `StrollToPoiList.create(listMemory, speed, close, maxDistance,
  closeTo)`: one of the listed POIs at random, while near `close_to`'s.
  """
  def stroll_to_list(list, speed, close, max, close_to) do
    Behavior.one_shot(
      [walk_target: :registered] ++ [{list, :present}, {close_to, :present}],
      0,
      fn self, next ->
        targets = Brain.get(self, list)
        {_, stay} = Brain.get(self, close_to)

        if targets == [] do
          {false, self, next}
        else
          {i, self} = Behavior.level_int(self, length(targets))

          case Enum.at(targets, i) do
            {dimension, pos} ->
              if dimension == self.world.dimension and
                   Pois.near_center?(stay, {self.x, self.y, self.z}, max) do
                if self.world.time > next,
                  do:
                    {true, Brain.set(self, :walk_target, walk_block(pos, speed, close)),
                     self.world.time + 100},
                  else: {true, self, next}
              else
                {false, self, next}
              end
          end
        end
      end
    )
  end

  defp near(self, memory, max) do
    case here(self, memory) do
      nil -> nil
      pos -> if Pois.near_center?(pos, {self.x, self.y, self.z}, max), do: pos
    end
  end

  ## Village-bound walks

  @doc """
  `VillageBoundRandomStroll.create(speed, h, v)`: in a village a land target
  around; outside it a step toward the nearest section closer to one.
  """
  def village_stroll(speed, h \\ 10, v \\ 7) do
    Behavior.one_shot([walk_target: :absent], fn self ->
      block = Self.block(self)

      {pos, self} =
        if Pois.village?(self.world, block) do
          RandomPos.land(self, h, v)
        else
          section = Pois.section(block)
          closer = closest_to_village(self.world, section, 2)

          if closer != section do
            {sx, sy, sz} = closer

            RandomPos.default_towards(
              self,
              h,
              v,
              {sx * 16 + 8.5, sy * 16 + 8.0, sz * 16 + 8.5},
              Float32.round(:math.pi() / 2)
            )
          else
            RandomPos.land(self, h, v)
          end
        end

      self =
        if pos,
          do: Brain.set(self, :walk_target, walk_point(pos, speed, 0)),
          else: Brain.erase(self, :walk_target)

      {true, self}
    end)
  end

  # `BehaviorUtils.findSectionClosestToVillage`: of the cube of sections
  # around, the first nearest to a village that is nearer than `center`.
  defp closest_to_village(world, {cx, cy, cz} = center, radius) do
    here = Pois.sections_to_village(world, center)

    {best, _} =
      for(
        x <- (cx - radius)..(cx + radius),
        y <- (cy - radius)..(cy + radius),
        z <- (cz - radius)..(cz + radius),
        do: {x, y, z}
      )
      |> Enum.map(&{&1, Pois.sections_to_village(world, &1)})
      |> Enum.filter(fn {_, d} -> d < here end)
      |> Enum.min_by(fn {_, d} -> d end, fn -> {center, here} end)

    best
  end

  @doc """
  `GoToClosestVillage.create(speed, close)`: outside a village, the best of
  five land targets toward one (by sections to it).
  """
  def go_to_village(speed, close) do
    Behavior.one_shot([walk_target: :absent], fn self ->
      if Pois.village?(self.world, Self.block(self)) do
        {false, self}
      else
        here = Pois.sections_to_village(self.world, Pois.section(Self.block(self)))

        weight = fn self, pos ->
          -Pois.sections_to_village(self.world, Pois.section(pos)) * 1.0
        end

        {target, self} =
          Enum.reduce_while(1..5, {nil, self}, fn _, {target, self} ->
            case RandomPos.land_weighted(self, 15, 7, weight) do
              {nil, self} ->
                {:cont, {target, self}}

              {{x, y, z} = point, self} ->
                there =
                  Pois.sections_to_village(
                    self.world,
                    Pois.section({floor(x), floor(y), floor(z)})
                  )

                cond do
                  there < here -> {:halt, {point, self}}
                  there == here -> {:cont, {point, self}}
                  true -> {:cont, {target, self}}
                end
            end
          end)

        self =
          if target,
            do: Brain.set(self, :walk_target, walk_point(target, speed, close)),
            else: self

        {true, self}
      end
    end)
  end

  @doc """
  `SetClosestHomeAsWalkTarget.create(speed)`: without a home, toward a bed
  it can path to (five at a time, each tried once in 40 ticks), 20 ticks
  apart.
  """
  def walk_to_closest_home(speed) do
    Behavior.one_shot(
      [walk_target: :absent, home: :absent],
      %{last: 0, cache: %{}, pending: nil},
      fn self, st ->
        now = self.world.time

        cond do
          st.pending != nil ->
            home_answer(self, st, speed)

          now - st.last < 20 ->
            {false, self, st}

          true ->
            block = Self.block(self)

            case Pois.closest(self.world, ["minecraft:home"], block, 48, :any) do
              nil ->
                {false, self, st}

              closest ->
                if Pois.dist_sq(closest, block) <= 4 do
                  {false, self, st}
                else
                  home_search(self, st, speed, block)
                end
            end
        end
      end
    )
  end

  defp home_search(self, st, speed, block) do
    {n, self} = Behavior.level_int(self, 20)
    last = self.world.time + n

    # The cache test counts every POI it does not skip, the fifth refused.
    {pois, {cache, tried}} =
      self.world
      |> Pois.in_range(["minecraft:home"], block, 48, :any)
      |> Enum.flat_map_reduce({st.cache, 0}, fn {_, pos} = poi, {cache, tried} ->
        cond do
          Map.has_key?(cache, pos) -> {[], {cache, tried}}
          tried + 1 >= 5 -> {[], {cache, tried + 1}}
          true -> {[poi], {Map.put(cache, pos, last + 40), tried + 1}}
        end
      end)

    st = %{st | last: last, cache: cache}

    case pois do
      [] ->
        {true, self, prune(st, tried)}

      _ ->
        {path, self} = Navigation.path_to_any(self, Enum.map(pois, &elem(&1, 1)), 1)

        case path do
          %{pending: n} ->
            {true, self, %{st | pending: {n, tried, self.world.time}}}

          path ->
            home_found(self, st, path, speed, tried)
        end
    end
  end

  defp home_found(self, st, path, speed, tried) do
    if path != nil and path.reached and Pois.type_at(self.world, path.target) != nil do
      {true, Brain.set(self, :walk_target, walk_block(path.target, speed, 1)), st}
    else
      {true, self, prune(st, tried)}
    end
  end

  defp home_answer(self, %{pending: {n, tried, at}} = st, speed) do
    case Map.fetch(self.world.paths, {self.uuid, n}) do
      {:ok, {path, _, _}} -> home_found(self, %{st | pending: nil}, path, speed, tried)
      {:ok, _} -> {false, self, %{st | pending: nil}}
      :error -> {false, self, if(self.world.time - at > 40, do: %{st | pending: nil}, else: st)}
    end
  end

  # Fewer than five tried: markers older than this round go.
  defp prune(st, tried) when tried < 5,
    do: %{
      st
      | cache: for({pos, until} <- st.cache, until >= st.last, into: %{}, do: {pos, until})
    }

  defp prune(st, _tried), do: st
end
