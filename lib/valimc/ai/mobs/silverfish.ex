defmodule Valimc.AI.Mobs.Silverfish do
  @moduledoc """
  Silverfish (VMC-043b6), as vanilla's `Silverfish`:

  - **Goals**: floating, climbing out of powder snow, waking its friends,
    melee, and with nothing to do slipping into a stone block beside it
    (`MergeWithStone`) or wandering, preferring spots over stone; whoever
    hurt it (and its kind around) and the player as targets.
  - **Friends**: hurt by something (or what always wakes them), a second
    later it breaks the infested blocks around it, nearest layers first,
    each one stopping the search by chance; each breaks into a silverfish
    while mobs may grief, else turns back to its stone (`{:wake_infested,
    cell, state, griefing}`).
  - **Merging**: an infested block takes the place of the stone it slips
    into (`{:infest, cell, state}`) and it is gone.
  - Its body faces its yaw (`tick` sets `yBodyRot`); its steps are events.
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, RandomPos, Self}
  alias Valimc.Data.Blocks

  @silverfish "minecraft:silverfish"

  @impl true
  def types, do: [@silverfish]

  @impl true
  def goals(_type) do
    {[
       {1, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "ClimbOnTopOfPowderSnowGoal", Goals.ClimbPowderSnow, [:jump], %{}},
       {3, "SilverfishWakeUpFriendsGoal", __MODULE__.WakeFriends, [], %{}},
       {4, "MeleeAttackGoal", Goals.MeleeAttack, [:move, :look],
        Goals.MeleeAttack.new(1.0, false)},
       {5, "SilverfishMergeWithStoneGoal", __MODULE__.Merge, [:move], __MODULE__.Merge.new()}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(alert: true, alert_types: [@silverfish])},
       {2, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true)}
     ]}
  end

  @impl true
  def finalize(self, reason), do: Valimc.AI.Spawn.mob(self, reason)

  @impl true
  def motion, do: [emission: :events]

  @impl true
  def tick_start(self), do: Self.mind(self, &%{&1 | body_yaw: self.yaw})

  @doc "`getWalkTargetValue`: ten over a stone it may infest."
  @impl true
  def walk_value(%Self{world: world} = self, {x, y, z} = pos) do
    if host?(Valimc.AI.World.block(world, {x, y - 1, z})),
      do: 10.0,
      else: RandomPos.family_value(self, pos)
  end

  ## Infested blocks

  @doc "`InfestedBlock.isCompatibleHostBlock`: a stone that has an infested form."
  def host?(nil), do: false
  def host?(state), do: infested_of(state) != nil

  @doc "`infestedStateByHost`: the infested form of a host state (nil for none)."
  def infested_of(state) do
    case Blocks.id("infested_" <> Blocks.name(Blocks.block_id(state))) do
      nil -> nil
      block -> carry(state, block)
    end
  end

  @doc "Whether a state is an infested block."
  def infested?(nil), do: false
  def infested?(state), do: String.starts_with?(Blocks.name(Blocks.block_id(state)), "infested_")

  @doc "`hostStateByInfested`: the stone an infested state hides."
  def host_of(state) do
    "infested_" <> host = Blocks.name(Blocks.block_id(state))
    carry(state, Blocks.id(host))
  end

  # The other block's state with the same properties (a deepslate's axis).
  defp carry(state, block) do
    name = Blocks.name(block)
    Blocks.state(name, Map.new(Blocks.properties(state)))
  end

  ## Hurts

  @doc """
  `hurtServer`: a hurt from something (or a damage type that always wakes
  them) tells its friends goal, whether or not the hurt takes.
  """
  @impl true
  def hurt(body, hit), do: notify(body, hit)

  @impl true
  def repelled(body, hit), do: notify(body, hit)

  defp notify(%{mob: %{ai: %Valimc.AI.Mind{} = mind} = mob} = body, hit) do
    type = Valimc.Living.DamageSource.type(hit.source)

    if hit[:attacker] != nil or
         Valimc.Protocol.DamageTypes.tag?(type, :always_triggers_silverfish) do
      own = mind.own || %{}

      own =
        if Map.get(own, :friends, 0) == 0,
          do: Map.put(own, :friends, Valimc.AI.Mth.reduced(20)),
          else: own

      %{body | mob: %{mob | ai: %{mind | own: own}}}
    else
      body
    end
  end

  defp notify(body, _hit), do: body
end

defmodule Valimc.AI.Mobs.Silverfish.WakeFriends do
  @moduledoc """
  `SilverfishWakeUpFriendsGoal`: while its friends countdown runs (a hurt
  started it, `Silverfish.hurt/2`), each update counts it down; at its end
  the infested blocks within ten blocks around and five up and down wake,
  layer by layer from its own outward, each stopping the search on a coin
  flip.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Silverfish

  defp friends(self), do: Map.get(self.mind.own || %{}, :friends, 0)
  defp put(self, n), do: Self.mind(self, &%{&1 | own: Map.put(&1.own || %{}, :friends, n)})

  def can_use(state, self), do: {friends(self) > 0, state, self}

  def tick(state, self) do
    n = friends(self) - 1
    self = put(self, n)
    if n <= 0, do: {state, wake(self)}, else: {state, self}
  end

  # The search order: 0, 1, -1, 2, -2, ...
  defp order(radius), do: [0 | Enum.flat_map(1..radius, &[&1, -&1])]

  defp wake(self) do
    {bx, by, bz} = Self.block(self)

    cells =
      for dy <- order(5), dx <- order(10), dz <- order(10), do: {bx + dx, by + dy, bz + dz}

    Enum.reduce_while(cells, self, fn cell, self ->
      state = World.block(self.world, cell)

      if Silverfish.infested?(state) do
        self = Self.effect(self, {:wake_infested, cell, state, self.world.mob_griefing})
        {heads, self} = Self.boolean(self)
        if heads, do: {:halt, self}, else: {:cont, self}
      else
        {:cont, self}
      end
    end)
  end
end

defmodule Valimc.AI.Mobs.Silverfish.Merge do
  @moduledoc """
  `SilverfishMergeWithStoneGoal`: with no target and nowhere to go, while
  mobs may grief, one update in five it picks a direction; a stone it may
  infest that way (from half a block up) takes it in: the block becomes
  infested and the silverfish is gone. Otherwise it strolls as
  `RandomStrollGoal` (speed 1, interval 10).
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.RandomStroll
  alias Valimc.AI.Mobs.Silverfish

  # `Direction.values()`: down, up, north, south, west, east.
  @directions [{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}]

  def new, do: %{stroll: RandomStroll.new(1.0, interval: 10), merge: nil}

  def can_use(state, self) do
    cond do
      World.target(self) != nil ->
        {false, state, self}

      not Navigation.done?(self.mind.navigation) ->
        {false, state, self}

      true ->
        {merge, self} = pick(self)

        if merge != nil do
          {true, %{state | merge: merge}, self}
        else
          {use, stroll, self} = RandomStroll.can_use(state.stroll, self)
          {use, %{state | stroll: stroll, merge: nil}, self}
        end
    end
  end

  defp pick(self) do
    if self.world.mob_griefing do
      {n, self} = Self.int(self, Mth.reduced(10))

      if n == 0 do
        {d, self} = Self.int(self, 6)
        {dx, dy, dz} = Enum.at(@directions, d)
        cell = {floor(self.x) + dx, floor(self.y + 0.5) + dy, floor(self.z) + dz}
        state = World.block(self.world, cell)
        {if(Silverfish.host?(state), do: {cell, state}), self}
      else
        {nil, self}
      end
    else
      {nil, self}
    end
  end

  def can_continue(%{merge: nil} = state, self) do
    {use, stroll, self} = RandomStroll.can_continue(state.stroll, self)
    {use, %{state | stroll: stroll}, self}
  end

  def can_continue(state, self), do: {false, state, self}

  def start(%{merge: nil} = state, self) do
    {stroll, self} = RandomStroll.start(state.stroll, self)
    {%{state | stroll: stroll}, self}
  end

  def start(%{merge: {cell, host}} = state, self) do
    self =
      self
      |> Self.effect({:infest, cell, Silverfish.infested_of(host)})
      |> Self.effect({:event, 20})
      |> Self.effect(:discard)

    {state, self}
  end

  def stop(%{merge: nil} = state, self) do
    {stroll, self} = RandomStroll.stop(state.stroll, self)
    {%{state | stroll: stroll}, self}
  end

  def stop(state, self), do: {state, self}
end
