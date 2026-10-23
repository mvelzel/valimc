defmodule Valimc.AI.Mobs.Fish do
  @moduledoc """
  Cod and salmon, and what every fish shares (`AbstractFish`,
  `AbstractSchoolingFish`; `Mobs.Pufferfish` and `Mobs.TropicalFish` use
  it). A fish panics when hurt, flees players within eight blocks and swims
  to random spots in water, steered by its own move control: it rises
  while its eyes are in water, eases its speed toward the wanted one and
  pushes up or down toward its target. It travels in water at a hundredth
  of its input with 0.9 drag, sinking slowly unless it has a target. Out of
  water it flops when it lands and loses air, drowning at -20.

  Schooling fish (cod, salmon, tropical fish) follow a leader: a fish with
  no school looks for one every ten seconds or so, joining a leader with
  room or leading the loners around it, and swims to its leader while
  within eleven blocks. A leader's school is its own state (`Mind.own`:
  `leader` and `school`), changed by its followers through `{:own, uuid,
  change}` effects.

  A salmon's size (small, medium, large) scales it.
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Mobs, Mth, Navigation, Random, Self, World}
  alias Valimc.Data.Float32

  @cod "minecraft:cod"
  @salmon "minecraft:salmon"
  @flop_side Float32.round(0.05)
  @flop_up Float32.round(0.4)

  @impl true
  def types, do: [@cod, @salmon]

  @impl true
  def goals(type), do: {fish_goals() ++ school_goals(type), []}

  @doc "`AbstractFish.registerGoals`."
  def fish_goals,
    do: [
      {0, "PanicGoal", Goals.Panic, [:move], Goals.Panic.new(1.25)},
      {2, "AvoidEntityGoal", Goals.AvoidEntity, [:move],
       Goals.AvoidEntity.new(&(&1.kind == :player), 8.0, 1.6, 1.4)},
      {4, "FishSwimGoal", Goals.RandomStroll, [:move],
       Goals.RandomStroll.new(1.0, interval: 40, swim: true, guard: &swims_alone?/1)}
    ]

  @doc "`AbstractSchoolingFish.registerGoals`: the flock goal."
  def school_goals(_type),
    do: [{5, "FollowFlockLeaderGoal", __MODULE__.FollowLeader, [], __MODULE__.FollowLeader.new()}]

  @doc "A dying one still runs its own tick (a dead fish flops)."
  @impl true
  def dying?, do: true

  @impl true
  def navigation, do: {:water, []}

  @impl true
  # Its travel when its AI does not choose one (dead, `NoAI`): no target.
  def motion, do: [fluid_pushed: false, travel: {:fish, true}]

  @impl true
  def swim_sound, do: "minecraft:entity.fish.swim"

  @impl true
  def data(@salmon), do: %{from_bucket: false, size: 1}
  def data(_type), do: %{from_bucket: false}

  @impl true
  def values(%{type: @salmon, data: data}),
    do: [{:fish_from_bucket, data.from_bucket, false}, {:salmon_type, data.size, 1}]

  def values(%{data: data}), do: [{:fish_from_bucket, data.from_bucket, false}]

  @impl true
  def dimensions(%{type: @salmon, data: %{size: size}}),
    do: scaled(@salmon, elem({0.5, 1.0, 1.5}, size))

  def dimensions(_body), do: nil

  @doc "`EntityDimensions.scale(f)` of type `type`'s dimensions."
  def scaled(type, factor) do
    facts = Valimc.Data.EntityTypes.fetch(type)
    f = Float32.round(factor)

    {Float32.round(Float32.round(facts.width) * f),
     Float32.round(Float32.round(facts.height) * f),
     Float32.round(Float32.round(facts.eye_height) * f)}
  end

  @doc """
  `finalizeSpawn`: a salmon's size from vanilla's weights (small 30,
  medium 50, large 15).
  """
  @impl true
  def finalize(%Self{type: @salmon, data: data} = self, reason) do
    {n, self} = Self.int(self, 95)

    size =
      cond do
        n < 30 -> 0
        n < 80 -> 1
        true -> 2
      end

    Valimc.AI.Spawn.mob(%{self | data: %{data | size: size}}, reason)
  end

  def finalize(self, reason), do: Valimc.AI.Spawn.mob(self, reason)

  @doc "`WaterAnimal.handleAirSupply`: full in water, else down to drowning."
  @impl true
  def air(_air, true), do: {300, 0.0}
  def air(air, false) when air - 1 <= -20, do: {0, 2.0}
  def air(air, false), do: {air - 1, 0.0}

  # ---- its tick

  @doc """
  `AbstractFish.aiStep` before its super: one out of water that landed
  flops up with a little sideways motion and its flop sound.
  """
  @impl true
  def before_ai(%Self{} = self) do
    if not Self.in_water?(self) and self.on_ground and self.mob.motion.vertical_collision do
      {a, self} = Self.float(self)
      {b, self} = Self.float(self)
      side = &Float32.round(Float32.round(Float32.round(&1 * 2.0) - 1.0) * @flop_side)
      {vx, vy, vz} = self.velocity
      self = %{self | velocity: {vx + side.(a), vy + @flop_up, vz + side.(b)}, on_ground: false}
      Valimc.AI.make_sound(self, flop_sound(self.type))
    else
      self
    end
  end

  defp flop_sound("minecraft:pufferfish"), do: "minecraft:entity.puffer_fish.flop"
  defp flop_sound("minecraft:" <> name), do: "minecraft:entity." <> name <> ".flop"

  @doc """
  `FishMoveControl.tick`: toward the wanted position while it navigates
  (speed eased an eighth of the way, a vertical push, its body turning
  with it), else still; it sinks unless it has a target.
  """
  @impl true
  def move_control(%Self{mob: mob} = self) do
    motion = mob.motion

    self =
      case motion.control do
        {:move_to, {wx, wy, wz}, modifier} ->
          if Navigation.done?(self.mind.navigation),
            do: set(self, 0.0, nil),
            else: steer(self, {wx, wy, wz}, modifier)

        _ ->
          set(self, 0.0, nil)
      end

    travel(self, {:fish, self.mind.target == nil})
  end

  defp steer(self, {wx, wy, wz}, modifier) do
    attribute = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:movement_speed")
    target = Float32.round(modifier * attribute)
    speed = Mth.lerp(Float32.round(0.125), Self.speed(self), target)
    {xd, yd, zd} = {wx - self.x, wy - self.y, wz - self.z}

    push =
      if yd != 0.0 do
        dd = :math.sqrt(xd * xd + yd * yd + zd * zd)
        speed * (yd / dd) * 0.1
      end

    self =
      if xd != 0.0 or zd != 0.0 do
        yaw = Mth.rotlerp(self.yaw, Mth.yaw(xd, zd), 90.0)
        Self.mind(%{self | yaw: yaw}, &%{&1 | body_yaw: yaw})
      else
        self
      end

    set(self, speed, push)
  end

  # `setSpeed`, its eyes lifting it, and the move control's push.
  defp set(%Self{mob: mob} = self, speed, push) do
    impulse = if push, do: {0.0, push, 0.0}, else: {0.0, 0.0, 0.0}
    motion = %{mob.motion | set: {speed * 1.0, true}, impulse: impulse}
    %{self | mob: %{mob | motion: motion}}
  end

  @doc "The kernel's travel for this tick (`MobMotion`'s `travel`)."
  def travel(%Self{mob: mob} = self, travel),
    do: %{self | mob: %{mob | motion: %{mob.motion | travel: travel}}}

  # ---- schools (`AbstractSchoolingFish`)

  @school %{leader: nil, school: 1}

  @doc "A fish's school state: its leader's uuid (or nil) and its school's size."
  def school(%{own: own}) when is_map(own),
    do: Map.merge(@school, Map.take(own, [:leader, :school]))

  def school(_), do: @school

  # A change to a fish's own state (`Mind.own`, nil for a fresh one).
  defp change(own, changes), do: Map.merge(Map.merge(@school, own || %{}), changes)

  defp max_school(@salmon), do: 5
  defp max_school(_type), do: 8

  @doc "`isFollower`: it has a leader that is alive."
  def follower?(%World{} = world, sensed) do
    case school(sensed).leader do
      nil -> false
      leader -> match?(%{alive: true}, World.entity(world, {:mob, leader}))
    end
  end

  # `canRandomSwim`: a schooling fish swims alone when it follows no one.
  defp swims_alone?(%Self{type: type} = self) do
    if type in Mobs.Fish.schooling(), do: not follower?(self.world, self.mind), else: true
  end

  @doc "The schooling types."
  def schooling, do: [@cod, @salmon, "minecraft:tropical_fish"]

  @doc """
  `AbstractSchoolingFish.tick` after its super: a leader alone now and then
  (one in 200 of the level's draws) finds its school gone.
  """
  @impl true
  def after_tick(%Self{} = self), do: school_tick(self)

  def school_tick(%Self{world: world} = self) do
    %{school: size} = school(self.mind)

    if size > 1 do
      {n, random} = Random.int(world.random, 200)
      self = %{self | world: %{world | random: random}}

      if n == 1 do
        box = World.inflate(Self.box(self), 8.0, 8.0, 8.0)
        near = World.mobs_in(self, [self.type], box)

        if length(near) <= 1,
          do: put_school(self, %{school(self.mind) | school: 1}),
          else: self
      else
        self
      end
    else
      self
    end
  end

  @doc "Set the fish's own school state."
  def put_school(self, school), do: Self.mind(self, &%{&1 | own: change(&1.own, school)})

  # A change to fish `uuid`'s school: its own at once, another's by effect.
  defp alter(self, uuid, fun) do
    if uuid == self.uuid,
      do: Self.mind(self, &%{&1 | own: fun.(&1.own)}),
      else: Self.effect(self, {:own, uuid, fun})
  end

  @doc "`follower.startFollowing(leader)`: its leader, and the leader's school grows."
  def follow(self, follower, leader) do
    self
    |> alter(follower, &change(&1, %{leader: leader}))
    |> alter(leader, &change(&1, %{school: school(%{own: &1}).school + 1}))
  end

  @doc "`stopFollowing`: it leaves its leader, whose school shrinks."
  def unfollow(self) do
    %{leader: leader} = school(self.mind)
    self = put_school(self, %{leader: nil})

    if leader,
      do: alter(self, leader, &change(&1, %{school: school(%{own: &1}).school - 1})),
      else: self
  end

  @doc "`canBeFollowed`: it leads a school with room."
  def followable?(sensed, type) do
    %{school: size} = school(sensed)
    size > 1 and size < max_school(type)
  end

  @doc "The maximum school of `type`."
  def max_school_size(type), do: max_school(type)
end

defmodule Valimc.AI.Mobs.Fish.FollowLeader do
  @moduledoc """
  `FollowFlockLeaderGoal`: a fish that leads no school follows its leader,
  re-pathing every ten updates while within eleven blocks of it; one with
  neither looks, every 100 to 109 updates, for a leader with room among the
  fish of its kind eight blocks around, or makes itself the leader of the
  loners there.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Fish

  # `nextStartTick` as made (vanilla draws it before the mob's random is
  # seeded; a fresh mind starts with the delay's least).
  def new, do: %{next: Mth.reduced(200), recalc: 0}

  def can_use(state, self) do
    school = Fish.school(self.mind)

    cond do
      school.school > 1 ->
        {false, state, self}

      Fish.follower?(self.world, self.mind) ->
        {true, state, self}

      state.next > 0 ->
        {false, %{state | next: state.next - 1}, self}

      true ->
        {n, self} = Self.int(self, 200)
        state = %{state | next: Mth.reduced(200 + rem(n, 20))}
        box = World.inflate(Self.box(self), 8.0, 8.0, 8.0)

        candidates =
          World.mobs_in(self, [self.type], box)
          |> Enum.map(&sensed(self, &1))
          |> Enum.filter(&(Fish.followable?(&1, self.type) or not Fish.follower?(self.world, &1)))

        leader =
          Enum.find(candidates, &Fish.followable?(&1, self.type)) || sensed(self, self)

        loners = Enum.reject(candidates, &Fish.follower?(self.world, &1))
        self = add_followers(self, leader, loners)
        {Fish.follower?(self.world, self.mind), state, self}
    end
  end

  # The fish as others read it, itself as it is now.
  defp sensed(self, %{uuid: uuid}) when uuid == self.uuid, do: %{uuid: uuid, own: self.mind.own}
  defp sensed(self, %Valimc.AI.Self{} = me), do: sensed(self, %{uuid: me.uuid})
  defp sensed(_self, other), do: other

  # `leader.addFollowers(loners)`: as many as its school has room for, in
  # order, but itself.
  defp add_followers(self, leader, loners) do
    room = Fish.max_school_size(self.type) - Fish.school(leader).school

    loners
    |> Enum.take(max(room, 0))
    |> Enum.reject(&(&1.uuid == leader.uuid))
    |> Enum.reduce(self, &Fish.follow(&2, &1.uuid, leader.uuid))
  end

  def can_continue(state, self) do
    leader = Fish.school(self.mind).leader

    within =
      case leader && World.entity(self.world, {:mob, leader}) do
        %{alive: true} = l -> World.distance_sq(self, l) <= 121.0
        _ -> false
      end

    {within, state, self}
  end

  def start(state, self), do: {%{state | recalc: 0}, self}

  def stop(state, self), do: {state, Fish.unfollow(self)}

  def tick(state, self) do
    recalc = state.recalc - 1

    if recalc <= 0 do
      state = %{state | recalc: adjusted(state, 10)}

      case World.entity(self.world, {:mob, Fish.school(self.mind).leader}) do
        %{alive: true} = leader ->
          {_, self} = Navigation.move_to_entity(self, leader, 1.0)
          {state, self}

        _ ->
          {state, self}
      end
    else
      {%{state | recalc: recalc}, self}
    end
  end
end
