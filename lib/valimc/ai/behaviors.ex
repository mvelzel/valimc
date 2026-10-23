defmodule Valimc.AI.Behaviors do
  @moduledoc """
  Brain behaviours shared by mobs with brains (VMC-041a2), as vanilla's
  `ai.behavior` classes build them: the look and walk sinks
  (`LookAtTargetSink`, `MoveToTargetSink`), look targets
  (`SetEntityLookTarget`, `SetLookAndInteract`), walks (`RandomStroll`,
  `SetWalkTargetFromLookTarget`, `InteractWith`, `GoToWantedItem`).

  Look and walk targets are trackers: `{:entity, ref, eye}` (an entity,
  its eyes when `eye`; an item's also where it lay, `{:entity, ref, eye,
  at}`, as vanilla's tracker keeps a removed item's last place) or
  `{:block, {x, y, z}, center}`; a walk target is `%{target, speed, close}`.
  """
  alias Valimc.AI.{Behavior, Brain, Navigation, RandomPos, Self, Sensors, World}
  alias Valimc.Data.Float32

  ## Trackers

  @doc "An entity tracker (`new EntityTracker(entity, eye)`)."
  def tracker(%{kind: :item} = e, eye), do: {:entity, World.ref(e), eye, {e.x, e.y, e.z}}
  def tracker(e, eye), do: {:entity, World.ref(e), eye}

  @doc "`PositionTracker.currentPosition`."
  def position(self, {:entity, ref, eye}) do
    case World.entity(self.world, ref) do
      nil -> nil
      e -> {e.x, if(eye, do: e.y + e.eye, else: e.y), e.z}
    end
  end

  def position(self, {:entity, ref, eye, {x, y, z}}) do
    case World.entity(self.world, ref) do
      nil -> {x, if(eye, do: y + 0.2125000059604645, else: y), z}
      _ -> position(self, {:entity, ref, eye})
    end
  end

  def position(_self, {:block, _block, center}), do: center

  @doc "`PositionTracker.currentBlockPosition`."
  def block(self, {:entity, ref, _eye}) do
    case World.entity(self.world, ref) do
      nil -> nil
      e -> {floor(e.x), floor(e.y), floor(e.z)}
    end
  end

  def block(self, {:entity, ref, eye, {x, y, z}}) do
    case World.entity(self.world, ref) do
      nil -> {floor(x), floor(y), floor(z)}
      _ -> block(self, {:entity, ref, eye})
    end
  end

  def block(_self, {:block, block, _center}), do: block

  @doc "`PositionTracker.isVisibleBy`: a living entity alive and in sight, anything else."
  def visible_by?(self, {:entity, ref, _eye}) do
    case World.entity(self.world, ref) do
      %{kind: :item} -> {true, self}
      nil -> {false, self}
      %{alive: false} -> {false, self}
      e -> Sensors.visible_contains?(self, e)
    end
  end

  def visible_by?(self, {:entity, _, _, _}), do: {true, self}
  def visible_by?(self, {:block, _, _}), do: {true, self}

  @doc "A block tracker of a point (`new WalkTarget(Vec3, ...)`: the block's center)."
  def point({x, y, z}) do
    block = {floor(x), floor(y), floor(z)}
    {bx, by, bz} = block
    {:block, block, {bx + 0.5, by + 0.5, bz + 0.5}}
  end

  @doc "`WalkTarget.reachedTarget`: within its distance, by Manhattan blocks."
  def reached?(self, %{target: target, close: close}) do
    case block(self, target) do
      nil ->
        false

      {tx, ty, tz} ->
        {x, y, z} = Self.block(self)
        abs(tx - x) + abs(ty - y) + abs(tz - z) <= close
    end
  end

  ## LookAtTargetSink

  defmodule LookSink do
    @moduledoc false
    alias Valimc.AI.{Behaviors, Brain, Self}

    def extra(state, self), do: {true, state, self}
    def start(state, self), do: {state, self}

    def still(state, self) do
      case Brain.get(self, :look_target) do
        nil ->
          {false, state, self}

        tracker ->
          {visible, self} = Behaviors.visible_by?(self, tracker)
          {visible, state, self}
      end
    end

    def tick(state, self) do
      case Brain.get(self, :look_target) do
        nil ->
          {state, self}

        tracker ->
          case Behaviors.position(self, tracker) do
            nil -> {state, self}
            point -> {state, Self.look_at(self, point)}
          end
      end
    end

    def stop(state, self), do: {state, Brain.erase(self, :look_target)}
  end

  @doc "`LookAtTargetSink(min, max)`."
  def look_sink(min, max), do: Behavior.timed(LookSink, [look_target: :present], {min, max})

  ## MoveToTargetSink

  defmodule MoveSink do
    @moduledoc false
    alias Valimc.AI.{Behaviors, Brain, Navigation, RandomPos, Self}

    def extra(%{cooldown: cooldown} = state, self) when cooldown > 0,
      do: {false, %{state | cooldown: cooldown - 1}, self}

    def extra(state, self) do
      walk = Brain.get(self, :walk_target)
      reached = Behaviors.reached?(self, walk)

      {computed, state, self} =
        if reached, do: {false, state, self}, else: compute(state, self, walk)

      if computed do
        {true, %{state | last: Behaviors.block(self, walk.target)}, self}
      else
        self = Brain.erase(self, :walk_target)
        self = if reached, do: Brain.erase(self, :cant_reach_walk_target_since), else: self
        {false, state, self}
      end
    end

    # `tryComputePath`.
    defp compute(state, self, walk) do
      target = Behaviors.block(self, walk.target)
      {path, self} = Navigation.path_to(self, block_point(target), 0)
      state = %{state | path: path, speed: walk.speed}

      if Behaviors.reached?(self, walk) do
        {false, state, Brain.erase(self, :cant_reach_walk_target_since)}
      else
        # One-node paths reach their target (VMC-041b's search may not).
        self =
          if path != nil,
            do: Brain.erase(self, :cant_reach_walk_target_since),
            else:
              if(Brain.has?(self, :cant_reach_walk_target_since),
                do: self,
                else: Brain.set(self, :cant_reach_walk_target_since, self.world.time)
              )

        if path != nil do
          {true, state, self}
        else
          {x, y, z} = target

          case RandomPos.default_towards(
                 self,
                 10,
                 7,
                 {x + 0.5, y * 1.0, z + 0.5},
                 Valimc.Data.Float32.round(:math.pi() / 2)
               ) do
            {nil, self} ->
              {false, state, self}

            {point, self} ->
              {path, self} = Navigation.path_to(self, point, 0)
              {path != nil, %{state | path: path}, self}
          end
        end
      end
    end

    defp block_point({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}

    def start(state, self) do
      self = Brain.set(self, :path, state.path)
      {_, self} = Navigation.follow(self, state.path, state.speed)
      {state, self}
    end

    def still(%{path: path, last: last} = state, self) when path != nil and last != nil do
      walk = Brain.get(self, :walk_target)

      spectator =
        case walk do
          %{target: {:entity, ref, _}} ->
            match?(%{mode: :spectator}, World.entity(self.world, ref))

          %{target: {:entity, ref, _, _}} ->
            match?(%{mode: :spectator}, World.entity(self.world, ref))

          _ ->
            false
        end

      {not Navigation.done?(self.mind.navigation) and walk != nil and
         not Behaviors.reached?(self, walk) and not spectator, state, self}
    end

    def still(state, self), do: {false, state, self}

    def tick(state, self) do
      current = self.mind.navigation.path

      {state, self} =
        if state.path != current,
          do: {%{state | path: current}, Brain.set(self, :path, current)},
          else: {state, self}

      if current != nil and state.last != nil do
        walk = Brain.get(self, :walk_target)
        {tx, ty, tz} = Behaviors.block(self, walk.target)
        {lx, ly, lz} = state.last

        if (tx - lx) ** 2 + (ty - ly) ** 2 + (tz - lz) ** 2 > 4 do
          case compute(state, self, walk) do
            {true, state, self} ->
              state = %{state | last: Behaviors.block(self, walk.target)}
              start(state, self)

            {false, state, self} ->
              {state, self}
          end
        else
          {state, self}
        end
      else
        {state, self}
      end
    end

    def stop(state, self) do
      walk = Brain.get(self, :walk_target)

      {state, self} =
        if walk != nil and not Behaviors.reached?(self, walk) and self.mind.navigation.stuck do
          {n, self} = Valimc.AI.Behavior.level_int(self, 40)
          {%{state | cooldown: n}, self}
        else
          {state, self}
        end

      self =
        self
        |> Navigation.stop()
        |> Brain.erase(:walk_target)
        |> Brain.erase(:path)

      {%{state | path: nil}, self}
    end
  end

  @doc "`MoveToTargetSink()` (150 to 250 ticks)."
  def move_sink,
    do:
      Behavior.timed(
        MoveSink,
        [cant_reach_walk_target_since: :registered, path: :absent, walk_target: :present],
        {150, 250},
        %{cooldown: 0, path: nil, last: nil, speed: 0.0}
      )

  ## One-shots

  @doc "`SetEntityLookTarget.create(predicate, maxDist)`."
  def look_target(predicate, distance) do
    max = Float32.round(Float32.round(distance) * Float32.round(distance))

    Behavior.one_shot(
      [look_target: :absent, nearest_visible_living_entities: :present],
      fn self ->
        {target, self} =
          Sensors.visible_closest(self, fn e ->
            predicate.(e) and World.distance_sq(self, e) <= max
          end)

        if target,
          do: {true, Brain.set(self, :look_target, {:entity, World.ref(target), true})},
          else: {false, self}
      end
    )
  end

  @doc "`SetLookAndInteract.create(type, range)` (players: `:player`)."
  def look_and_interact(kind, range) do
    max = range * range

    Behavior.one_shot(
      [
        look_target: :registered,
        interaction_target: :absent,
        nearest_visible_living_entities: :present
      ],
      fn self ->
        {target, self} =
          Sensors.visible_closest(self, fn e ->
            World.distance_sq(self, e) <= max and is?(e, kind)
          end)

        if target do
          self =
            self
            |> Brain.set(:interaction_target, World.ref(target))
            |> Brain.set(:look_target, {:entity, World.ref(target), true})

          {true, self}
        else
          {false, self}
        end
      end
    )
  end

  @doc "Whether a sensed entity is of `kind` (`:player`, or a mob type)."
  def is?(%{kind: :player}, :player), do: true
  def is?(%{kind: :mob, type: type}, type), do: true
  def is?(_entity, _kind), do: false

  @doc "`RandomStroll.stroll(speed)`: a land target ten blocks around, or none."
  def stroll(speed) do
    Behavior.one_shot([walk_target: :absent], fn self ->
      {pos, self} = RandomPos.land(self, 10, 7)

      self =
        case pos do
          nil ->
            Brain.erase(self, :walk_target)

          pos ->
            Brain.set(self, :walk_target, %{
              target: point(pos),
              speed: Float32.round(speed),
              close: 0
            })
        end

      {true, self}
    end)
  end

  @doc "`SetWalkTargetFromLookTarget.create(speed, close)` behind `predicate` (`triggerIf`)."
  def walk_to_look_target(predicate, speed, close) do
    Behavior.one_shot([], fn self ->
      if predicate.(self) and not Brain.has?(self, :walk_target) and
           Brain.has?(self, :look_target) do
        target = Brain.get(self, :look_target)

        {true,
         Brain.set(self, :walk_target, %{
           target: target,
           speed: Float32.round(speed),
           close: close
         })}
      else
        {false, self}
      end
    end)
  end

  @doc "`InteractWith.of(type, range, INTERACTION_TARGET, speed, stop)`."
  def interact_with(type, range, speed, stop) do
    max = range * range

    Behavior.one_shot(
      [
        interaction_target: :registered,
        look_target: :registered,
        walk_target: :absent,
        nearest_visible_living_entities: :present
      ],
      fn self ->
        {any, self} = Sensors.visible_closest(self, &is?(&1, type))

        if any do
          {closest, self} =
            Sensors.visible_closest(self, fn e ->
              World.distance_sq(self, e) <= max and is?(e, type)
            end)

          self =
            if closest do
              ref = World.ref(closest)

              self
              |> Brain.set(:interaction_target, ref)
              |> Brain.set(:look_target, {:entity, ref, true})
              |> Brain.set(:walk_target, %{
                target: {:entity, ref, false},
                speed: Float32.round(speed),
                close: stop
              })
            else
              self
            end

          {true, self}
        else
          {false, self}
        end
      end
    )
  end

  @doc "`GoToWantedItem.create(predicate, speed, interrupt, maxDist)`."
  def go_to_wanted_item(predicate, speed, interrupt, distance) do
    walk = if interrupt, do: :registered, else: :absent

    Behavior.one_shot(
      [
        look_target: :registered,
        walk_target: walk,
        nearest_visible_wanted_item: :present,
        item_pickup_cooldown_ticks: :registered
      ],
      fn self ->
        item = World.entity(self.world, Brain.get(self, :nearest_visible_wanted_item))

        if item != nil and not Brain.has?(self, :item_pickup_cooldown_ticks) and predicate.(self) and
             World.distance_sq(self, item) < distance * distance do
          self =
            self
            |> Brain.set(:walk_target, %{
              target: tracker(item, false),
              speed: Float32.round(speed),
              close: 0
            })
            |> Brain.set(:look_target, tracker(item, true))

          {true, self}
        else
          {false, self}
        end
      end
    )
  end
end
