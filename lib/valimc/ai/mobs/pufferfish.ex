defmodule Valimc.AI.Mobs.Pufferfish do
  @moduledoc """
  `Pufferfish`: a fish (`Mobs.Fish`) that puffs up while anything living it
  fears is within two blocks (not creative players, not the types of
  `not_scary_for_pufferfish`): half puffed at once, fully after 40 ticks,
  and down a step after 60 and again after 100 ticks once clear. Puffed,
  it stings the mobs and players it touches (1 plus its puff, and Poison for
  three seconds a step). Its puff scales it (half, 0.7, full).

  Its counters are its own state (`Mind.own`, not saved, as vanilla's).
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Mobs.Fish, Self, World}
  alias Valimc.Data.EntityTypes

  @type_name "minecraft:pufferfish"
  @blow_up "minecraft:entity.puffer_fish.blow_up"
  @blow_out "minecraft:entity.puffer_fish.blow_out"

  @impl true
  def types, do: [@type_name]

  @doc "A dying one still runs its own tick (it flops)."
  @impl true
  def dying?, do: true

  @impl true
  def goals(_type),
    do:
      {Fish.fish_goals() ++
         [{1, "PufferfishPuffGoal", __MODULE__.Puff, [], __MODULE__.Puff.new()}], []}

  @impl true
  defdelegate navigation, to: Fish
  @impl true
  defdelegate motion, to: Fish
  @impl true
  defdelegate swim_sound, to: Fish
  @impl true
  defdelegate before_ai(self), to: Fish
  @impl true
  defdelegate move_control(self), to: Fish
  @impl true
  defdelegate air(air, in_water), to: Fish

  @impl true
  def data(_type), do: %{from_bucket: false, puff: 0}

  @impl true
  def values(%{data: data}),
    do: [{:fish_from_bucket, data.from_bucket, false}, {:puff_state, data.puff, 0}]

  @impl true
  def dimensions(%{data: %{puff: puff}}), do: Fish.scaled(@type_name, elem({0.5, 0.7, 1.0}, puff))

  @doc "Its counters (`inflateCounter`, `deflateTimer`)."
  def counters(%{own: %{inflate: _} = own}), do: own
  def counters(_mind), do: %{inflate: 0, deflate: 0}

  defp put(self, changes),
    do: Self.mind(self, &%{&1 | own: Map.merge(counters(&1), changes)})

  @doc "`Pufferfish.tick` before its super: puffing up and down."
  @impl true
  def tick_start(%Self{data: data} = self) do
    %{inflate: inflate, deflate: deflate} = counters(self.mind)

    cond do
      inflate > 0 ->
        self =
          cond do
            data.puff == 0 -> puff(self, 1, @blow_up)
            inflate > 40 and data.puff == 1 -> puff(self, 2, @blow_up)
            true -> self
          end

        put(self, %{inflate: inflate + 1})

      data.puff != 0 ->
        self =
          cond do
            deflate > 60 and data.puff == 2 -> puff(self, 1, @blow_out)
            deflate > 100 and data.puff == 1 -> puff(self, 0, @blow_out)
            true -> self
          end

        put(self, %{deflate: deflate + 1})

      true ->
        self
    end
  end

  defp puff(self, state, sound) do
    self = Valimc.AI.make_sound(self, sound)
    old = self.data.puff
    self = %{self | data: %{self.data | puff: state}}
    if state > old, do: fudge(self, old), else: self
  end

  # `refreshDimensions` as it grows (`fudgePositionAfterSizeChange`): it
  # keeps its centre where the grown box is free (no block in the way;
  # where one is, it stays put).
  defp fudge(%Self{} = self, old) do
    {_, old_height, _} = Fish.scaled(@type_name, elem({0.5, 0.7, 1.0}, old))
    {width, height, eye} = Fish.scaled(@type_name, elem({0.5, 0.7, 1.0}, self.data.puff))
    center = self.y + old_height / 2.0
    y = center - height / 2.0
    half = width / 2.0
    box = {self.x - half, y, self.z - half, self.x + half, y + height, self.z + half}

    if Valimc.AI.Shapes.free?(self.world, box),
      do: %{self | y: y, width: width, height: height, eye: eye},
      else: %{self | width: width, height: height, eye: eye}
  end

  @doc "Whether it fears `target` (`SCARY_MOB` over non-combat conditions)."
  def scary?(%{kind: :player} = target),
    do: target.alive and target.mode not in [:creative, :spectator]

  def scary?(%{kind: :mob, type: type, alive: alive}),
    do: alive and not EntityTypes.tag?(type, "not_scary_for_pufferfish")

  def scary?(_target), do: false

  @doc """
  `Pufferfish.aiStep` after its super: puffed, it stings the mobs it touches
  (`{:sting, target, amount, poison ticks}`); players it touches are stung
  by their own touch (`playerTouch`), which this effect stands for too.
  """
  @impl true
  def after_ai(%Self{data: %{puff: puff}} = self) when puff > 0 do
    box = World.inflate(Self.box(self), 0.3, 0.3, 0.3)

    own = Self.box(self)

    # A player touches what its box, a block wider and half a block taller,
    # meets (`Player.touch`).
    touched =
      Enum.filter(self.world.players, fn p ->
        scary?(p) and World.intersects?(World.inflate(World.box(p), 1.0, 0.5, 1.0), own)
      end) ++
        Enum.filter(World.mob_list(self.world), fn m ->
          m.uuid != self.uuid and scary?(m) and World.intersects?(World.box(m), box)
        end)

    Enum.reduce(touched, self, fn target, self ->
      Self.effect(self, {:sting, World.ref(target), 1.0 + puff, 60 * puff})
    end)
  end

  def after_ai(self), do: self
end

defmodule Valimc.AI.Mobs.Pufferfish.Puff do
  @moduledoc """
  `PufferfishPuffGoal`: runs while anything the pufferfish fears is within
  two blocks of its box; starting it starts the puffing.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Pufferfish

  def new, do: %{}

  def can_use(state, self) do
    box = World.inflate(Self.box(self), 2.0, 2.0, 2.0)

    near =
      Enum.any?(
        self.world.players,
        &(Pufferfish.scary?(&1) and World.intersects?(World.box(&1), box))
      ) or
        Enum.any?(World.mob_list(self.world), fn m ->
          m.uuid != self.uuid and Pufferfish.scary?(m) and World.intersects?(World.box(m), box)
        end)

    {near, state, self}
  end

  def start(state, self),
    do:
      {state,
       Self.mind(
         self,
         &%{&1 | own: Map.merge(Pufferfish.counters(&1), %{inflate: 1, deflate: 0})}
       )}

  def stop(state, self),
    do: {state, Self.mind(self, &%{&1 | own: Map.merge(Pufferfish.counters(&1), %{inflate: 0})})}
end
