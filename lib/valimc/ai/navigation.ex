defmodule Valimc.AI.Navigation do
  @moduledoc """
  Vanilla's `PathNavigation` (VMC-041a, VMC-041b) and its kinds: ground
  (`GroundPathNavigation`: targets raised to their surface), water-bound,
  flying and amphibious. A path comes from vanilla's search
  (`Valimc.AI.Paths`, `PathFinder` with the kind's node evaluator) and is
  followed node by node into the move control's wanted position, cutting
  corners where vanilla does, with stuck detection (too little progress in
  100 ticks), the node timeout (three times the time the mob's speed
  needs), cauldron nodes raised, and recomputation (`recomputePath`, at
  most once in 20 ticks).

  Where the search runs is the world's (`World.search/2`): at once
  (oracles, tests), or deferred in an owner (VMC-041b), which runs it as a
  job over published snapshots and never waits. A deferred path is pending
  (`%{pending: n}`): goals see a path, the mob holds still, and its next
  tick installs the result (`receive/1`), drops it when the owner found it
  stale (its chunks republished since) and recomputes, or gives it up when
  nothing came within `@pending_limit` ticks.
  """
  alias Valimc.AI.{Paths, Self, World}
  alias Valimc.Data.Float32

  @pending_limit 40

  defstruct path: nil,
            speed: 0.0,
            tick: 0,
            last_stuck_check: 0,
            last_stuck_pos: {0.0, 0.0, 0.0},
            timeout_node: {0, 0, 0},
            timeout_timer: 0,
            last_timeout_check: 0,
            timeout_limit: 0.0,
            target: nil,
            reach: 0,
            stuck: false,
            delayed: false,
            last_recompute: 0,
            requests: 0,
            kind: :ground,
            evaluator: :walk,
            can_float: false,
            can_open_doors: false,
            can_pass_doors: true,
            can_walk_over_fences: false,
            # `GroundPathNavigation.setAvoidSun` (VMC-043b: skeletons by day).
            avoid_sun: false

  @doc "A navigation of `kind` (`:ground`, `:water`, `:fly`, `:amphibious`) with `options`."
  def new(kind \\ :ground, options \\ []) do
    evaluator =
      case kind do
        :ground -> :walk
        :water -> {:swim, Keyword.get(options, :breaching, false)}
        :fly -> :fly
        :amphibious -> {:amphibious, false}
      end

    struct!(
      %__MODULE__{kind: kind, evaluator: evaluator, can_pass_doors: kind != :water},
      Keyword.delete(options, :breaching)
    )
  end

  @doc "`isDone`: no path, or every node reached (a pending path is not done)."
  def done?(%__MODULE__{path: nil}), do: true
  def done?(%__MODULE__{path: %{pending: _}}), do: false
  def done?(%__MODULE__{path: %{nodes: nodes, index: index}}), do: index >= tuple_size(nodes)

  @doc "`stop`."
  def stop(%Self{} = self), do: put(self, %{nav(self) | path: nil})

  @doc "`setSpeedModifier`."
  def speed(%Self{} = self, speed), do: put(self, %{nav(self) | speed: speed * 1.0})

  @doc "`setCanFloat` (a `FloatGoal`'s; water-bound and amphibious navigations ignore it)."
  def can_float(%Self{} = self) do
    nav = nav(self)
    if nav.kind in [:water, :amphibious], do: self, else: put(self, %{nav | can_float: true})
  end

  @doc "`moveTo(x, y, z, speed)`: a path to the block holding the point, reach 1."
  def move_to(%Self{} = self, point, speed) do
    {path, self} = path_to(self, point, 1)
    follow(self, path, speed)
  end

  @doc "`moveTo(entity, speed)`: a path to the entity (none keeps the old one)."
  def move_to_entity(%Self{} = self, target, speed, reach \\ 1) do
    case path_to_entity(self, target, reach) do
      {nil, self} -> {false, self}
      {path, self} -> follow(self, path, speed)
    end
  end

  @doc """
  `createPath(entity, reach)`: `{path | nil, self}`. Ground and flying
  navigations path to its block; the others from a block above the mob,
  sixteen blocks wider.
  """
  def path_to_entity(%Self{} = self, t, reach) do
    block = {floor(t.x), floor(t.y), floor(t.z)}

    if nav(self).kind in [:ground, :fly],
      do: path_to_block(self, block, reach),
      else: create(self, [block], 16, true, reach)
  end

  @doc "`createPath(x, y, z, reach)`: `{path | nil, self}`."
  def path_to(%Self{} = self, {x, y, z}, reach),
    do: path_to_block(self, {floor(x), floor(y), floor(z)}, reach)

  # `createPath(pos, reach)`: a ground navigation raises the target to its
  # surface (none where its chunk cannot be read).
  defp path_to_block(%Self{world: world} = self, target, reach) do
    if nav(self).kind == :ground do
      if World.block(world, target) == nil,
        do: {nil, self},
        else: create(self, [surface(world, target)], 8, false, reach)
    else
      create(self, [target], 8, false, reach)
    end
  end

  # `PathNavigation.createPath(targets, offset, above, reach)`: a found
  # path's target resets the stuck timeout.
  defp create(%Self{world: world} = self, targets, offset, above, reach) do
    nav = nav(self)

    cond do
      targets == [] ->
        {nil, self}

      self.y < world.min_y ->
        {nil, self}

      not updatable?(self) ->
        {nil, self}

      nav.path != nil and not done?(nav) and nav.target in targets ->
        {nav.path, self}

      true ->
        request = Paths.request(self, targets, offset, above, reach)

        case World.search(world, request) do
          {nil, random, _} ->
            {nil, Self.mind(self, &%{&1 | random: random})}

          {path, random, _} ->
            self = Self.mind(self, &%{&1 | random: random})
            {path, put(self, found(nav(self), path.target, reach))}

          :deferred ->
            n = nav.requests + 1
            [target | _] = targets
            pending = %{pending: n, since: nav.tick, target: target, trim: false}
            nav = %{found(nav, target, reach) | requests: n}

            {pending, self |> put(nav) |> Self.effect({:path, self.uuid, n, request})}
        end
    end
  end

  defp found(nav, target, reach),
    do: %{
      nav
      | target: target,
        reach: reach,
        timeout_node: {0, 0, 0},
        timeout_timer: 0,
        timeout_limit: 0.0,
        stuck: false
    }

  @doc """
  The search results the owner holds for this mob (`world.paths`, by
  `{uuid, request}`): the
  pending path's own installed (trimmed when it was followed), a stale one
  dropped and recomputed, and a pending path nothing answered given up.
  """
  def receive(%Self{} = self) do
    nav = nav(self)

    case nav.path do
      %{pending: n} = pending ->
        case Map.fetch(self.world.paths, {self.uuid, n}) do
          {:ok, result} ->
            install(self, pending, result)

          :error ->
            if nav.tick - pending.since > @pending_limit,
              do: put(self, %{nav | path: nil}),
              else: self
        end

      _ ->
        self
    end
  end

  defp install(self, _pending, :stale), do: recompute(put(self, %{nav(self) | path: nil}))

  defp install(self, _pending, {nil, _random, _chunks}), do: put(self, %{nav(self) | path: nil})

  defp install(self, pending, {path, _random, _chunks}) do
    path = if pending.trim, do: self |> trim(path) |> then(&sun(self, &1)), else: path
    put(self, %{nav(self) | path: path})
  end

  @doc "`moveTo(path, speed)`: `{started, self}`."
  def follow(%Self{} = self, nil, _speed), do: {false, put(self, %{nav(self) | path: nil})}

  def follow(%Self{} = self, %{pending: _} = path, speed) do
    nav = nav(self)
    path = if same?(nav.path, path), do: nav.path, else: path
    nav = %{nav | path: %{path | trim: true}, speed: speed * 1.0}
    position = temp_position(self, nav)
    {true, put(self, %{nav | last_stuck_check: nav.tick, last_stuck_pos: position})}
  end

  def follow(%Self{} = self, path, speed) do
    nav = nav(self)
    nav = if same?(nav.path, path), do: nav, else: %{nav | path: path}

    if done?(nav) do
      {false, put(self, nav)}
    else
      nav = %{nav | path: sun(self, trim(self, nav.path))}
      position = temp_position(self, nav)

      {true,
       put(self, %{nav | speed: speed * 1.0, last_stuck_check: nav.tick, last_stuck_pos: position})}
    end
  end

  # `Path.sameAs`: the same nodes (a pending path is the same request).
  defp same?(%{pending: n}, %{pending: n}), do: true
  defp same?(%{nodes: nodes}, %{nodes: nodes}), do: true
  defp same?(_, _), do: false

  # `findSurfacePosition`: down to the first non-air below an air target (up
  # past air above when there is none), then up past solid blocks.
  defp surface(world, {x, y, z} = target) do
    target =
      if World.air?(world, target) do
        case Enum.find((y - 1)..world.min_y//-1, &(not World.air?(world, {x, &1, z}))) do
          nil ->
            up = Enum.find((y + 1)..world.max_y//1, &(not World.air?(world, {x, &1, z})))
            {x, up || world.max_y + 1, z}

          below ->
            {x, below + 1, z}
        end
      else
        target
      end

    {x, y, z} = target

    if World.solid?(world, target) do
      up = Enum.find((y + 1)..world.max_y//1, &(not World.solid?(world, {x, &1, z})))
      {x, up || world.max_y + 1, z}
    else
      target
    end
  end

  # `trimPath`: a node in a cauldron stands on its rim, and the node after
  # it no lower than that.
  defp trim(%Self{world: world}, path), do: trim(world, path)

  defp trim(world, %{nodes: nodes, types: types} = path) do
    {nodes, types} =
      Enum.reduce(0..(tuple_size(nodes) - 1)//1, {nodes, types}, fn i, {nodes, types} ->
        {x, y, z} = elem(nodes, i)

        if cauldron?(World.block(world, {x, y, z})) do
          nodes = put_elem(nodes, i, {x, y + 1, z})

          if i + 1 < tuple_size(nodes) and y >= elem(elem(nodes, i + 1), 1) do
            {nx, _, nz} = elem(nodes, i + 1)
            # `cloneAndMove` of the cauldron's node: its type goes along.
            {put_elem(nodes, i + 1, {nx, y + 1, nz}), put_elem(types, i + 1, elem(types, i))}
          else
            {nodes, types}
          end
        else
          {nodes, types}
        end
      end)

    %{path | nodes: nodes, types: types}
  end

  # `GroundPathNavigation.trimPath` avoiding the sun: from the shade, the
  # path ends before its first node under the open sky.
  defp sun(%Self{mind: %{navigation: %{avoid_sun: true}}} = self, %{nodes: nodes} = path) do
    if World.sees_sky?(self.world, {floor(self.x), floor(self.y + 0.5), floor(self.z)}) do
      path
    else
      case Enum.find(0..(tuple_size(nodes) - 1)//1, &World.sees_sky?(self.world, elem(nodes, &1))) do
        nil ->
          path

        i ->
          %{
            path
            | nodes: nodes |> Tuple.to_list() |> Enum.take(i) |> List.to_tuple(),
              types: path.types |> Tuple.to_list() |> Enum.take(i) |> List.to_tuple()
          }
      end
    end
  end

  defp sun(_self, path), do: path

  @doc "`GroundPathNavigation.setAvoidSun`."
  def avoid_sun(%Self{} = self, avoid), do: put(self, %{nav(self) | avoid_sun: avoid})

  @cauldrons MapSet.new(
               for name <- ["cauldron", "water_cauldron", "lava_cauldron", "powder_snow_cauldron"],
                   state <- Valimc.Data.Blocks.states(name),
                   do: state
             )

  defp cauldron?(state), do: MapSet.member?(@cauldrons, state)

  @doc """
  `PathNavigation.tick`: recompute a delayed path, follow the path
  (advancing past a reached node, detecting a stuck mob) and set the move
  control's wanted position at the next node's floor.
  """
  def tick(%Self{} = self) do
    nav = nav(self)
    self = put(self, %{nav | tick: nav.tick + 1})
    self = if nav.delayed, do: recompute(self), else: self
    nav = nav(self)

    cond do
      done?(nav) or match?(%{pending: _}, nav.path) ->
        self

      nav.kind == :fly ->
        fly_tick(self)

      true ->
        self = if updatable?(self), do: follow_path(self), else: airborne(self)
        nav = nav(self)

        if done?(nav) do
          self
        else
          {x, y, z} = entity_position(self, nav.path)
          Self.move_to(self, {x, ground_y(self, {x, y, z}), z}, nav.speed)
        end
    end
  end

  # `FlyingPathNavigation.tick`: a node is reached in its block while
  # flying cannot update the path, and the wanted position is the node's.
  defp fly_tick(self) do
    self =
      if updatable?(self) do
        follow_path(self)
      else
        nav = nav(self)
        {px, py, pz} = entity_position(self, nav.path)

        if Self.block(self) == {floor(px), floor(py), floor(pz)},
          do: put(self, advance(nav)),
          else: self
      end

    nav = nav(self)

    if done?(nav),
      do: self,
      else: Self.move_to(self, entity_position(self, nav.path), nav.speed)
  end

  # `recomputePath`: at most once in 20 ticks and only while the path can
  # update, else delayed.
  defp recompute(self) do
    nav = nav(self)
    time = self.world.time

    cond do
      time - nav.last_recompute <= 20 or not updatable?(self) ->
        put(self, %{nav | delayed: true})

      nav.target != nil ->
        {path, self} = path_to_block(put(self, %{nav | path: nil}), nav.target, nav.reach)
        put(self, %{nav(self) | path: path, last_recompute: time, delayed: false})

      true ->
        self
    end
  end

  # Off the ground and out of liquid: a node passed over is reached.
  defp airborne(self) do
    nav = nav(self)
    {mx, my, mz} = temp_position(self, nav)
    {px, py, pz} = entity_position(self, nav.path)

    if my > py and not self.on_ground and floor(mx) == floor(px) and floor(mz) == floor(pz),
      do: put(self, advance(nav)),
      else: self
  end

  # `followThePath`.
  defp follow_path(self) do
    nav = nav(self)
    position = temp_position(self, nav)
    width = self.width

    max_distance =
      if width > 0.75,
        do: Float32.round(width / 2.0),
        else: Float32.round(0.75 - Float32.round(width / 2.0))

    %{nodes: nodes, types: types, index: index} = nav.path
    {nx, ny, nz} = elem(nodes, index)
    vertical = if nav.kind == :water, do: 0.5, else: 1.0

    close =
      abs(self.x - (nx + 0.5)) < max_distance and abs(self.z - (nz + 0.5)) < max_distance and
        abs(self.y - ny) < vertical

    nav =
      if close or
           (Paths.cut_corner?(elem(types, index)) and toward_next?(self, nav.path, position)),
         do: advance(nav),
         else: nav

    stuck_detection(put(self, nav), position)
  end

  # `shouldTargetNextNodeInDirection`.
  defp toward_next?(self, %{nodes: nodes, index: index} = path, position) do
    if index + 1 >= tuple_size(nodes) do
      false
    else
      current = bottom_center(elem(nodes, index))

      cond do
        distance_sq(position, current) >= 4.0 ->
          false

        can_move_directly?(self, position, entity_position(self, path)) ->
          true

        true ->
          next = bottom_center(elem(nodes, index + 1))
          to_current = sub(current, position)
          to_next = sub(next, position)
          current_sq = dot(to_current, to_current)
          closer = dot(to_next, to_next) < current_sq

          if not closer and not (current_sq < 0.5) do
            false
          else
            dot(normalize(to_next), normalize(to_current)) < 0.0
          end
      end
    end
  end

  # `canMoveDirectly`: a ground navigation never; others when a collider
  # ray (through fluids for a flier) clears from the mob to half its height
  # over the next node (an amphibian only in a liquid).
  defp can_move_directly?(self, from, {x, y, z}) do
    fluid =
      case nav(self).kind do
        :ground -> nil
        :fly -> :any
        :water -> :none
        :amphibious -> if Self.in_liquid?(self), do: :none
      end

    fluid != nil and
      Valimc.Physics.Clip.clip(
        from,
        {x, y + self.height * 0.5, z},
        fluid,
        &World.block(self.world, &1),
        :collider
      ).miss
  end

  defp bottom_center({x, y, z}), do: {x + 0.5, y * 1.0, z + 0.5}
  defp sub({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp dot({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz

  # `Vec3.normalize`: below 1e-5F long, zero.
  defp normalize({x, y, z} = v) do
    length = :math.sqrt(dot(v, v))

    if length < 9.999999747378752e-6,
      do: {0.0, 0.0, 0.0},
      else: {x / length, y / length, z / length}
  end

  defp advance(%{path: path} = nav), do: %{nav | path: %{path | index: path.index + 1}}

  defp stuck_detection(self, position) do
    nav = nav(self)
    speed = Self.speed(self)

    nav =
      if nav.tick - nav.last_stuck_check > 100 do
        effective = if speed >= 1.0, do: speed, else: Float32.round(speed * speed)
        threshold = Float32.round(Float32.round(effective * 100.0) * 0.25)

        nav =
          if distance_sq(position, nav.last_stuck_pos) < Float32.round(threshold * threshold),
            do: %{nav | stuck: true, path: nil},
            else: %{nav | stuck: false}

        %{nav | last_stuck_check: nav.tick, last_stuck_pos: position}
      else
        nav
      end

    if nav.path != nil and not done?(nav) do
      node = elem(nav.path.nodes, nav.path.index)
      time = self.world.time

      nav =
        if node == nav.timeout_node do
          %{nav | timeout_timer: nav.timeout_timer + (time - nav.last_timeout_check)}
        else
          distance = :math.sqrt(distance_sq(position, bottom_center(node)))
          limit = if speed > 0.0, do: distance / speed * 20.0, else: 0.0
          %{nav | timeout_node: node, timeout_limit: limit}
        end

      nav =
        if nav.timeout_limit > 0.0 and nav.timeout_timer > nav.timeout_limit * 3.0,
          do: %{
            nav
            | timeout_node: {0, 0, 0},
              timeout_timer: 0,
              timeout_limit: 0.0,
              stuck: false,
              path: nil
          },
          else: nav

      put(self, %{nav | last_timeout_check: time})
    else
      put(self, nav)
    end
  end

  @doc "`getPath().getNextEntityPos(mob)` of an unfinished path, else nil."
  def next_entity_position(%Self{} = self) do
    case nav(self) do
      %__MODULE__{path: %{nodes: nodes, index: index} = path} when index < tuple_size(nodes) ->
        entity_position(self, path)

      _ ->
        nil
    end
  end

  # `Path.getNextEntityPos`: the node's corner plus half the mob's rounded-up width.
  defp entity_position(self, %{nodes: nodes, index: index}) do
    {x, y, z} = elem(nodes, index)
    offset = trunc(Float32.round(self.width + 1.0)) * 0.5
    {x + offset, y * 1.0, z + offset}
  end

  # `getGroundY`: over air the point's own height, else the floor below it;
  # water-bound and amphibious navigations keep the node's height.
  defp ground_y(%Self{world: world} = self, {x, y, z}) do
    {bx, by, bz} = {floor(x), floor(y), floor(z)}

    cond do
      nav(self).kind in [:water, :amphibious] -> y
      World.air?(world, {bx, by - 1, bz}) -> y
      true -> floor_level(world, {bx, by, bz})
    end
  end

  @doc "`WalkNodeEvaluator.getFloorLevel`: the top of the collision shape below."
  def floor_level(world, {x, y, z}) do
    below = y - 1

    top =
      case World.block(world, {x, below, z}) do
        nil -> 0.0
        state -> top(state)
      end

    below + top
  end

  defp top(state) do
    case Valimc.Data.BlockFacts.collision(state) do
      {kind, %{boxes: boxes}} when kind in [:fixed, :offset] and boxes != [] ->
        boxes |> Enum.map(&elem(&1, 4)) |> Enum.max()

      _ ->
        0.0
    end
  end

  # `getTempMobPos`: a ground navigation's the surface of a floatable fluid
  # it floats in, else its feet raised half a block; water-bound and
  # amphibious its middle; a flier its position.
  defp temp_position(self, nav) do
    case nav.kind do
      :ground ->
        y =
          if Self.in_water?(self) and nav.can_float,
            do: surface_y(self),
            else: floor(self.y + 0.5)

        {self.x, y * 1.0, self.z}

      :fly ->
        {self.x, self.y, self.z}

      _ ->
        {self.x, self.y + self.height * 0.5, self.z}
    end
  end

  defp surface_y(self) do
    start = floor(self.y)
    surface_y(self, {floor(self.x), floor(self.z)}, start, start, 0)
  end

  defp surface_y(self, {x, z} = column, start, y, steps) do
    cond do
      World.fluid(self.world, {x, y, z}) != :water -> y
      steps + 1 > 16 -> start
      true -> surface_y(self, column, start, y + 1, steps + 1)
    end
  end

  # `canUpdatePath`: a ground navigation on the ground or in a liquid; a
  # water-bound one breaching or in a liquid; fliers and amphibians always
  # (nothing rides yet).
  defp updatable?(self) do
    case nav(self) do
      %{kind: :ground} -> self.on_ground or Self.in_liquid?(self)
      %{kind: :water, evaluator: {:swim, breaching}} -> breaching or Self.in_liquid?(self)
      _ -> true
    end
  end

  defp distance_sq({ax, ay, az}, {bx, by, bz}) do
    {dx, dy, dz} = {ax - bx, ay - by, az - bz}
    dx * dx + dy * dy + dz * dz
  end

  defp nav(%Self{mind: mind}), do: mind.navigation
  defp put(%Self{} = self, nav), do: Self.mind(self, &%{&1 | navigation: nav})
end
