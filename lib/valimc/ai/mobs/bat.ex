defmodule Valimc.AI.Mobs.Bat do
  @moduledoc """
  `Bat`: an ambient flier with no goals. A resting bat hangs under a block
  that conducts redstone, still and snapped to the block's top, now and
  then turning its head; a player within four blocks, losing its perch or a
  hurt wakes it (level event 1025, its takeoff). Awake it steers its motion
  toward a random spot near it (picked again now and then, or when it gets
  there or the spot fills), sinks slowly as its vertical motion fades, and
  now and then perches under a conductor above it. Its forward input is
  its move control's (none), it neither pushes nor is pushed and never
  takes fall damage. Resting is its saved flag (`BatFlags`); its target
  spot is its own state (`Mind.own`).
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Mth, Self, World}
  alias Valimc.Data.Float32

  @type_name "minecraft:bat"
  @tenth Float32.round(0.1)
  @lift Float32.round(0.7)

  @impl true
  def types, do: [@type_name]

  @impl true
  def goals(_type), do: {[], []}

  @impl true
  def data(_type), do: %{resting: true}

  @impl true
  def values(%{data: data}), do: [{:bat_flags, if(data.resting, do: 1, else: 0), 0}]

  @impl true
  def motion, do: [pushable: false, pushes: false, emission: :events]

  @impl true
  def falls?, do: false

  @doc "`getVoicePitch`: the usual, times 0.95."
  @impl true
  def voice(_type, _data), do: {1.0, 0.95}

  @doc "`getAmbientSound`: a resting bat only one time in four."
  @impl true
  def ambient_sound(%Self{data: %{resting: true}} = self) do
    {n, self} = Self.int(self, 4)
    {if(n == 0, do: "minecraft:entity.bat.ambient"), self}
  end

  def ambient_sound(_self), do: "minecraft:entity.bat.ambient"

  @doc "`hurtServer`: a hurt wakes it."
  @impl true
  def hurt(%{data: %{resting: true} = data} = body, _hit),
    do: %{body | data: %{data | resting: false}}

  def hurt(body, _hit), do: body

  @doc "`customServerAiStep`: resting, or flying toward its spot."
  @impl true
  def custom_step(%Self{data: %{resting: true}} = self) do
    pos = Self.block(self)
    {x, y, z} = pos

    if World.conductor?(self.world, {x, y + 1, z}) do
      {n, self} = Self.int(self, 200)

      self =
        if n == 0 do
          {head, self} = Self.int(self, 360)
          %{self | head: head * 1.0}
        else
          self
        end

      conditions = World.conditions(false, range: 4.0)

      case World.nearest_player(self, conditions, self.x, self.y, self.z) do
        {nil, self} -> self
        {_player, self} -> wake(self, pos)
      end
    else
      wake(self, pos)
    end
  end

  def custom_step(%Self{} = self) do
    {x, y, z} = Self.block(self)
    {self, target} = target(self)
    {tx, ty, tz} = target
    {dx, dy, dz} = {tx + 0.5 - self.x, ty + 0.1 - self.y, tz + 0.5 - self.z}

    # Its motion after `aiStep`'s dead zone, steered a tenth of the way.
    {mx, my, mz} =
      Enum.map(Tuple.to_list(self.velocity), &if(abs(&1) < 0.003, do: 0.0, else: &1))
      |> List.to_tuple()

    impulse =
      {(sign(dx) * 0.5 - mx) * @tenth, (sign(dy) * @lift - my) * @tenth,
       (sign(dz) * 0.5 - mz) * @tenth}

    {ix, _, iz} = impulse
    yaw = Mth.yaw(mx + ix, mz + iz)
    yaw = Float32.round(self.yaw + Mth.wrap(Float32.round(yaw - self.yaw)))
    self = %{self | yaw: yaw, mob: %{self.mob | motion: %{self.mob.motion | impulse: impulse}}}

    {n, self} = Self.int(self, 100)

    if n == 0 and World.conductor?(self.world, {x, y + 1, z}),
      do: %{self | data: %{self.data | resting: true}},
      else: self
  end

  defp wake(self, pos),
    do: %{self | data: %{self.data | resting: false}} |> Self.effect({:level_event, pos, 1025, 0})

  # Its spot: dropped once filled or below the world, picked again when
  # missing, one time in thirty, or within two blocks.
  defp target(%Self{world: world} = self) do
    target =
      case own(self) do
        {_, ty, _} = t -> if World.air?(world, t) and ty > world.min_y, do: t
        nil -> nil
      end

    {again, self} =
      case target do
        nil ->
          {true, self}

        {tx, ty, tz} ->
          {n, self} = Self.int(self, 30)
          {cx, cy, cz} = {tx + 0.5 - self.x, ty + 0.5 - self.y, tz + 0.5 - self.z}
          {n == 0 or cx * cx + cy * cy + cz * cz < 4.0, self}
      end

    if again do
      {a, self} = Self.int(self, 7)
      {b, self} = Self.int(self, 7)
      {c, self} = Self.int(self, 6)
      {d, self} = Self.int(self, 7)
      {e, self} = Self.int(self, 7)

      t =
        {floor(self.x + a - b), floor(self.y + c - 2.0), floor(self.z + d - e)}

      {Self.mind(self, &%{&1 | own: t}), t}
    else
      {self, target}
    end
  end

  defp own(%Self{mind: %{own: {_, _, _} = t}}), do: t
  defp own(_self), do: nil

  defp sign(v) when v > 0.0, do: 1.0
  defp sign(v) when v < 0.0, do: -1.0
  defp sign(_v), do: 0.0

  @doc """
  `Bat.tick` after its super: a resting bat stops and hangs from the top of
  its block; a flying one's vertical motion fades.
  """
  @impl true
  def after_tick(%Self{data: %{resting: true}} = self),
    do: %{self | velocity: {0.0, 0.0, 0.0}, y: floor(self.y) + 1.0 - self.height}

  def after_tick(%Self{velocity: {vx, vy, vz}} = self), do: %{self | velocity: {vx, vy * 0.6, vz}}
end
