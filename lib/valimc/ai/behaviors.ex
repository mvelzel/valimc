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

    # `tryComputePath`. A target entity gone from the world (killed, picked
    # up, moved off the section) has no place to path to.
    defp compute(state, self, walk) do
      case Behaviors.block(self, walk.target) do
        nil -> {false, state, self}
        target -> compute(state, self, walk, target)
      end
    end

    defp compute(state, self, walk, target) do
      {path, self} = Navigation.path_to(self, block_point(target), 0)
      state = %{state | path: path, speed: walk.speed}

      if Behaviors.reached?(self, walk) do
        {false, state, Brain.erase(self, :cant_reach_walk_target_since)}
      else
        # A pending path (VMC-041b) counts as reaching until it arrives.
        self =
          if path != nil and Map.get(path, :reached, true),
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

      walk = Brain.get(self, :walk_target)
      target = walk && Behaviors.block(self, walk.target)

      if current != nil and state.last != nil and target != nil do
        {tx, ty, tz} = target
        {lx, ly, lz} = state.last

        if (tx - lx) ** 2 + (ty - ly) ** 2 + (tz - lz) ** 2 > 4 do
          case compute(state, self, walk) do
            {true, state, self} ->
              start(%{state | last: target}, self)

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

  @doc "`MoveToTargetSink(min, max)` (by default 150 to 250 ticks)."
  def move_sink(min \\ 150, max \\ 250),
    do:
      Behavior.timed(
        MoveSink,
        [cant_reach_walk_target_since: :registered, path: :absent, walk_target: :present],
        {min, max},
        %{cooldown: 0, path: nil, last: nil, speed: 0.0}
      )

  @doc """
  `BehaviorUtils.setWalkAndLookTargetMemories(mob, pos, speed, close)`: look
  at the block and walk to it.
  """
  def walk_and_look(self, {x, y, z} = pos, speed, close) do
    tracker = {:block, pos, {x + 0.5, y + 0.5, z + 0.5}}

    self
    |> Brain.set(:look_target, tracker)
    |> Brain.set(:walk_target, %{target: tracker, speed: Float32.round(speed), close: close})
  end

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

  @doc """
  `BehaviorBuilder.triggerIf(predicate, oneShot)`: the one-shot, only while
  `predicate.(self)` holds.
  """
  def trigger_if(predicate, %{trigger: trigger} = one_shot),
    do: %{
      one_shot
      | trigger: fn self -> if predicate.(self), do: trigger.(self), else: {false, self} end
    }

  @doc "Whether a sensed entity is of `kind` (`:player`, or a mob type)."
  def is?(%{kind: :player}, :player), do: true
  def is?(%{kind: :mob, type: type}, type), do: true
  def is?(_entity, _kind), do: false

  @doc """
  `RandomStroll.swim(speed)`: in water, toward a swimmable target by
  vanilla's widening tiers (`RandomPos.swim_target/1`); none found clears
  the walk target.
  """
  def swim_stroll(speed) do
    Behavior.one_shot([walk_target: :absent], fn self ->
      if Self.in_water?(self) do
        {pos, self} = RandomPos.swim_target(self)

        self =
          case pos do
            nil -> Brain.erase(self, :walk_target)
            pos -> Brain.set(self, :walk_target, %{target: point(pos), speed: speed, close: 0})
          end

        {true, self}
      else
        {false, self}
      end
    end)
  end

  @doc """
  `RandomStroll.stroll(speed)` (`stroll(speed, h, v)`): a land target ten
  (`h`) blocks around and seven (`v`) up or down, or none.
  """
  def stroll(speed, h \\ 10, v \\ 7, may \\ fn _ -> true end) do
    Behavior.one_shot([walk_target: :absent], fn self ->
      if may.(self), do: strolled(self, speed, h, v), else: {false, self}
    end)
  end

  defp strolled(self, speed, h, v) do
    (fn ->
       {pos, self} = RandomPos.land(self, h, v)

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
     end).()
  end

  @doc "`SetWalkTargetFromLookTarget.create(speed, close)` behind `predicate` (`triggerIf`)."
  def walk_to_look_target(predicate, speed, close) do
    Behavior.one_shot([], fn self ->
      if predicate.(self) and not Brain.has?(self, :walk_target) and
           Brain.has?(self, :look_target) do
        target = Brain.get(self, :look_target)

        speed = if is_function(speed), do: speed.(self), else: Float32.round(speed)

        {true,
         Brain.set(self, :walk_target, %{
           target: target,
           speed: speed,
           close: close
         })}
      else
        {false, self}
      end
    end)
  end

  @doc """
  `InteractWith.of(type, range, INTERACTION_TARGET, speed, stop)`; `opts`:
  `memory` (the target's memory), `self` and `target` (the filters of
  `InteractWith.of(type, range, selfFilter, targetFilter, ...)`).
  """
  def interact_with(type, range, speed, stop, opts \\ []) do
    max = range * range
    memory = Keyword.get(opts, :memory, :interaction_target)
    self_filter = Keyword.get(opts, :self, fn _ -> true end)
    target_filter = Keyword.get(opts, :target, fn _ -> true end)
    valid = &(is?(&1, type) and target_filter.(&1))

    Behavior.one_shot(
      [
        {memory, :registered},
        look_target: :registered,
        walk_target: :absent,
        nearest_visible_living_entities: :present
      ],
      fn self ->
        {any, self} =
          if self_filter.(self), do: Sensors.visible_closest(self, valid), else: {nil, self}

        if any do
          {closest, self} =
            Sensors.visible_closest(self, fn e ->
              World.distance_sq(self, e) <= max and valid.(e)
            end)

          self =
            if closest do
              ref = World.ref(closest)

              self
              |> Brain.set(memory, ref)
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

  ## Swim

  defmodule Swim do
    @moduledoc false
    alias Valimc.AI.Self

    def extra(state, self), do: {deep?(self), state, self}
    def start(state, self), do: {state, self}
    def still(state, self), do: {deep?(self), state, self}

    def tick(%{chance: chance} = state, self) do
      {f, self} = Self.float(self)
      {state, if(f < chance, do: Self.jump(self), else: self)}
    end

    def stop(state, self), do: {state, self}

    # `isInFluidDeeperThan(getFluidJumpThreshold(), ENTITY_FLOATABLE) || isInLava`.
    defp deep?(self), do: self.mob.motion.water > Self.jump_threshold(self) or Self.in_lava?(self)
  end

  @doc "`Swim(chance)`: in water deeper than its jump threshold, or in lava, it jumps."
  def swim(chance),
    do: Behavior.timed(Swim, [], {60, 60}, %{chance: Float32.round(chance)})

  ## InteractWithDoor

  @doors MapSet.new(
           Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:mob_interactable_doors"]
         )

  @doc "Whether `state` is a door mobs open (`MOB_INTERACTABLE_DOORS`)."
  def mob_door?(state), do: MapSet.member?(@doors, Valimc.Data.Blocks.block_id(state))

  @doc "Whether a door state is open."
  def door_open?(state),
    do: state |> Valimc.Data.Blocks.properties() |> List.keyfind("open", 0) == {"open", "true"}

  @doc """
  `InteractWithDoor.create()`: along its path the mob opens a closed door it
  comes from or goes to (`{:door, pos, true}`, the owner's to apply) and
  remembers it; doors it passed it closes again unless one of its kind is
  coming through or the door is more than 3 blocks away. A node it checked
  waits 20 ticks.
  """
  def interact_with_door do
    Behavior.one_shot(
      [path: :present, doors_to_close: :registered, nearest_living_entities: :registered],
      %{last: nil, cooldown: 0},
      fn self, st ->
        case self.mind.navigation.path do
          %{nodes: nodes, index: index} when index > 0 and index < tuple_size(nodes) ->
            next = elem(nodes, index)

            {wait, st} =
              cond do
                st.last == next -> {false, %{st | cooldown: 20}}
                st.cooldown - 1 > 0 -> {true, %{st | cooldown: st.cooldown - 1}}
                true -> {false, %{st | cooldown: st.cooldown - 1}}
              end

            if wait do
              {false, self, st}
            else
              from = elem(nodes, index - 1)
              self = through_doors(self, from, next)
              {true, self, %{st | last: next}}
            end

          _ ->
            {false, self, st}
        end
      end
    )
  end

  defp through_doors(self, from, to) do
    self =
      case World.block(self.world, from) do
        state when is_integer(state) ->
          if mob_door?(state) do
            self = if door_open?(state), do: self, else: open_door(self, from, true)
            remember_door(self, from)
          else
            self
          end

        _ ->
          self
      end

    self =
      case World.block(self.world, to) do
        state when is_integer(state) ->
          if mob_door?(state) and not door_open?(state),
            do: self |> open_door(to, true) |> remember_door(to),
            else: self

        _ ->
          self
      end

    case Brain.get(self, :doors_to_close) do
      nil -> self
      doors -> close_doors(self, from, to, doors)
    end
  end

  defp open_door(self, pos, open), do: Self.effect(self, {:door, pos, open})

  defp remember_door(self, pos) do
    door = {self.world.dimension, pos}
    doors = Brain.get(self, :doors_to_close) || []
    if door in doors, do: self, else: Brain.set(self, :doors_to_close, doors ++ [door])
  end

  @doc """
  `closeDoorsThatIHaveOpenedOrPassedThrough`: each remembered door but the
  ones at `from` and `to` (nil for none) is forgotten, and closed when it is
  near, still an open door, and no mob of its kind comes through it.
  """
  def close_doors(self, from, to, doors) do
    {kept, self} =
      Enum.reduce(doors, {[], self}, fn {dimension, pos} = door, {kept, self} ->
        cond do
          pos == from or pos == to ->
            {[door | kept], self}

          dimension != self.world.dimension or
              not near_center?(pos, self, 3.0) ->
            {kept, self}

          true ->
            state = World.block(self.world, pos)

            cond do
              state == nil or not mob_door?(state) -> {kept, self}
              not door_open?(state) -> {kept, self}
              coming_through?(self, pos) -> {kept, self}
              true -> {kept, open_door(self, pos, false)}
            end
        end
      end)

    Brain.set(self, :doors_to_close, Enum.reverse(kept))
  end

  defp near_center?({bx, by, bz}, self, distance) do
    {dx, dy, dz} = {bx + 0.5 - self.x, by + 0.5 - self.y, bz + 0.5 - self.z}
    dx * dx + dy * dy + dz * dz < distance * distance
  end

  # `areOtherMobsComingThroughDoor`: one of its type within 2 blocks whose
  # path goes from or to the door.
  defp coming_through?(self, pos) do
    for ref <- Brain.get(self, :nearest_living_entities) || [],
        %{kind: :mob, type: type, path_step: step} = m <- [World.entity(self.world, ref)],
        type == self.type,
        near_center?(pos, %{x: m.x, y: m.y, z: m.z}, 2.0),
        reduce: false do
      acc -> acc or match?({^pos, _}, step) or match?({_, ^pos}, step)
    end
  end

  ## SetWalkTargetAwayFrom

  @doc """
  `SetWalkTargetAwayFrom.entity(memory, speed, distance, interrupt)`: closer
  than `distance` to the remembered entity, a land target 16 blocks away
  from it (ten tries); a walk at this speed already leading away stays.
  """
  def walk_away_from(memory, speed, distance, interrupt) do
    speed = Float32.round(speed)

    Behavior.one_shot([{:walk_target, :registered}, {memory, :present}], fn self ->
      walk = Brain.get(self, :walk_target)

      case World.entity(self.world, Brain.get(self, memory)) do
        nil ->
          {false, self}

        _ when walk != nil and not interrupt ->
          {false, self}

        from ->
          {ax, ay, az} = avoid = {from.x, from.y, from.z}
          {dx, dy, dz} = {self.x - ax, self.y - ay, self.z - az}

          cond do
            dx * dx + dy * dy + dz * dz >= distance * distance ->
              {false, self}

            walk != nil and walk.speed == speed and leading_toward?(self, walk, avoid) ->
              {false, self}

            true ->
              {true, flee(self, avoid, speed)}
          end
      end
    end)
  end

  defp leading_toward?(self, walk, {ax, ay, az}) do
    case position(self, walk.target) do
      nil ->
        false

      {tx, ty, tz} ->
        (tx - self.x) * (ax - self.x) + (ty - self.y) * (ay - self.y) +
          (tz - self.z) * (az - self.z) >=
          0.0
    end
  end

  defp flee(self, avoid, speed) do
    Enum.reduce_while(1..10, self, fn _, self ->
      case RandomPos.land_away(self, 16, 7, avoid) do
        {nil, self} ->
          {:cont, self}

        {pos, self} ->
          {:halt, Brain.set(self, :walk_target, %{target: point(pos), speed: speed, close: 0})}
      end
    end)
  end
end
