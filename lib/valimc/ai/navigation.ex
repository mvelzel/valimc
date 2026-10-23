defmodule Valimc.AI.Navigation do
  @moduledoc """
  Vanilla's `GroundPathNavigation` (VMC-041a): paths to a block or an
  entity's block raised to its surface, followed node by node into the move
  control's wanted position at the node's floor, with stuck detection (too
  little progress in 100 ticks) and the node timeout (three times the time
  the mob's speed needs), and cauldron nodes raised.

  Until VMC-041b's search, a path is one node, the target: everything after
  finding it is vanilla's. `MobAiOracle` answers vanilla's path finder the
  same way, so the fixtures check the following.
  """
  alias Valimc.AI.{Self, World}
  alias Valimc.Data.Float32

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
            can_float: false

  @doc "`isDone`: no path, or every node reached."
  def done?(%__MODULE__{path: nil}), do: true
  def done?(%__MODULE__{path: %{nodes: nodes, index: index}}), do: index >= length(nodes)

  @doc "`stop`."
  def stop(%Self{} = self), do: put(self, %{nav(self) | path: nil})

  @doc "`setSpeedModifier`."
  def speed(%Self{} = self, speed), do: put(self, %{nav(self) | speed: speed * 1.0})

  @doc "`setCanFloat` (a `FloatGoal`'s)."
  def can_float(%Self{} = self), do: put(self, %{nav(self) | can_float: true})

  @doc "`moveTo(x, y, z, speed)`: a path to the block holding the point, reach 1."
  def move_to(%Self{} = self, point, speed) do
    {path, self} = path_to(self, point, 1)
    follow(self, path, speed)
  end

  @doc "`moveTo(entity, speed)`: a path to the entity's block (none keeps the old one)."
  def move_to_entity(%Self{} = self, target, speed, reach \\ 1) do
    case path_to_entity(self, target, reach) do
      {nil, self} -> {false, self}
      {path, self} -> follow(self, path, speed)
    end
  end

  @doc "`createPath(entity, reach)`: `{path | nil, self}`."
  def path_to_entity(%Self{} = self, t, reach),
    do: path(self, {floor(t.x), floor(t.y), floor(t.z)}, reach)

  @doc "`createPath(x, y, z, reach)`: `{path | nil, self}`."
  def path_to(%Self{} = self, {x, y, z}, reach),
    do: path(self, {floor(x), floor(y), floor(z)}, reach)

  # `GroundPathNavigation.createPath(pos, reach)`: the target raised to its
  # surface (none where its chunk cannot be read), then `createPath`'s
  # checks; a new path's target resets the stuck timeout.
  defp path(%Self{world: world} = self, target, reach) do
    if World.block(world, target) == nil do
      {nil, self}
    else
      target = surface(world, target)
      nav = nav(self)

      cond do
        self.y < world.min_y ->
          {nil, self}

        not updatable?(self) ->
          {nil, self}

        nav.path != nil and not done?(nav) and nav.target == target ->
          {nav.path, self}

        true ->
          nav = %{
            nav
            | target: target,
              reach: reach,
              timeout_node: {0, 0, 0},
              timeout_timer: 0,
              timeout_limit: 0.0,
              stuck: false
          }

          {%{nodes: [target], index: 0, target: target}, put(self, nav)}
      end
    end
  end

  @doc "`moveTo(path, speed)`: `{started, self}`."
  def follow(%Self{} = self, nil, _speed), do: {false, put(self, %{nav(self) | path: nil})}

  def follow(%Self{} = self, path, speed) do
    nav = nav(self)
    # `sameAs`: a path through the same nodes keeps the old one (and how far it got).
    nav = if nav.path != nil and nav.path.nodes == path.nodes, do: nav, else: %{nav | path: path}

    if done?(nav) do
      {false, put(self, nav)}
    else
      nav = %{nav | path: trim(self.world, nav.path)}
      position = temp_position(self, nav)

      {true,
       put(self, %{nav | speed: speed * 1.0, last_stuck_check: nav.tick, last_stuck_pos: position})}
    end
  end

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

  # `trimPath`: a node in a cauldron stands on its rim.
  defp trim(world, %{nodes: nodes} = path) do
    %{
      path
      | nodes:
          Enum.map(nodes, fn {x, y, z} = node ->
            if cauldron?(World.block(world, node)), do: {x, y + 1, z}, else: node
          end)
    }
  end

  @cauldrons MapSet.new(
               for name <- ["cauldron", "water_cauldron", "lava_cauldron", "powder_snow_cauldron"],
                   state <- Valimc.Data.Blocks.states(name),
                   do: state
             )

  defp cauldron?(state), do: MapSet.member?(@cauldrons, state)

  @doc """
  `PathNavigation.tick`: follow the path (advancing past a reached node,
  detecting a stuck mob) and set the move control's wanted position at the
  next node's floor.
  """
  def tick(%Self{} = self) do
    nav = nav(self)
    nav = %{nav | tick: nav.tick + 1}
    self = put(self, nav)

    if done?(nav) do
      self
    else
      self =
        if updatable?(self) do
          follow_path(self)
        else
          airborne(self)
        end

      nav = nav(self)

      if done?(nav) do
        self
      else
        {x, y, z} = entity_position(self, nav.path)
        Self.move_to(self, {x, ground_y(self.world, {x, y, z}), z}, nav.speed)
      end
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

  defp follow_path(self) do
    nav = nav(self)
    position = temp_position(self, nav)
    width = self.width

    max_distance =
      if width > 0.75,
        do: Float32.round(width / 2.0),
        else: Float32.round(0.75 - Float32.round(width / 2.0))

    {nx, ny, nz} = Enum.at(nav.path.nodes, nav.path.index)

    close =
      abs(self.x - (nx + 0.5)) < max_distance and abs(self.z - (nz + 0.5)) < max_distance and
        abs(self.y - ny) < 1.0

    # One node: never a next node to cut toward.
    nav = if close, do: advance(nav), else: nav
    stuck_detection(put(self, nav), position)
  end

  defp advance(%{path: path} = nav), do: %{nav | path: %{path | index: path.index + 1}}

  defp stuck_detection(self, position) do
    nav = nav(self)
    speed = Self.speed(self)

    {self, nav} =
      if nav.tick - nav.last_stuck_check > 100 do
        effective = if speed >= 1.0, do: speed, else: Float32.round(speed * speed)
        threshold = Float32.round(Float32.round(effective * 100.0) * 0.25)

        nav =
          if distance_sq(position, nav.last_stuck_pos) < Float32.round(threshold * threshold),
            do: %{nav | stuck: true, path: nil},
            else: %{nav | stuck: false}

        {self, %{nav | last_stuck_check: nav.tick, last_stuck_pos: position}}
      else
        {self, nav}
      end

    if nav.path != nil and not done?(nav) do
      node = Enum.at(nav.path.nodes, nav.path.index)
      time = self.world.time

      nav =
        if node == nav.timeout_node do
          %{nav | timeout_timer: nav.timeout_timer + (time - nav.last_timeout_check)}
        else
          {x, y, z} = node
          distance = :math.sqrt(distance_sq(position, {x + 0.5, y * 1.0, z + 0.5}))
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

  # `Path.getNextEntityPos`: the node's corner plus half the mob's rounded-up width.
  defp entity_position(self, %{nodes: nodes, index: index}) do
    {x, y, z} = Enum.at(nodes, index)
    offset = trunc(Float32.round(self.width + 1.0)) * 0.5
    {x + offset, y * 1.0, z + offset}
  end

  # `getGroundY`: over air the point's own height, else the floor below it.
  defp ground_y(world, {x, y, z}) do
    {bx, by, bz} = {floor(x), floor(y), floor(z)}

    if World.air?(world, {bx, by - 1, bz}) do
      y
    else
      floor_level(world, {bx, by, bz})
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

  # `getTempMobPos`: the surface of a floatable fluid the mob floats in, else
  # its feet raised half a block.
  defp temp_position(self, nav) do
    y =
      if Self.in_water?(self) and nav.can_float do
        surface_y(self)
      else
        floor(self.y + 0.5)
      end

    {self.x, y * 1.0, self.z}
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

  # `canUpdatePath`: on the ground or in a liquid.
  defp updatable?(self), do: self.on_ground or Self.in_liquid?(self)

  defp distance_sq({ax, ay, az}, {bx, by, bz}) do
    {dx, dy, dz} = {ax - bx, ay - by, az - bz}
    dx * dx + dy * dy + dz * dz
  end

  defp nav(%Self{mind: mind}), do: mind.navigation
  defp put(%Self{} = self, nav), do: Self.mind(self, &%{&1 | navigation: nav})
end
