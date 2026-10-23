defmodule Valimc.AI.Goals.Tempt do
  @moduledoc """
  `TemptGoal`: the nearest player within its tempt range holding an item it
  wants (`items`, a predicate on item ids) in either hand, followed and
  looked at until within the stop distance; a mob that can be scared stops
  when the player moves or turns close by. After it stops it calms down for
  100 ticks.
  """
  use Valimc.AI.Goal

  def new(speed, items, can_scare, stop \\ 2.5),
    do: %{
      speed: speed * 1.0,
      items: items,
      scare: can_scare,
      stop: stop * 1.0,
      player: nil,
      at: {0.0, 0.0, 0.0},
      rotation: {0.0, 0.0},
      calm: 0,
      running: false
    }

  def can_use(%{calm: calm} = state, self) when calm > 0,
    do: {false, %{state | calm: calm - 1}, self}

  def can_use(state, self) do
    range = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:tempt_range")

    conditions =
      World.conditions(false,
        range: range,
        sight: false,
        select: fn p ->
          state.items.(p.equipment[:mainhand]) or state.items.(p.equipment[:offhand])
        end
      )

    {player, self} = World.nearest_player(self, conditions, self.x, self.y, self.z)
    {player != nil, %{state | player: World.ref(player)}, self}
  end

  def can_continue(%{scare: false} = state, self), do: can_use(state, self)

  def can_continue(state, self) do
    case World.entity(self.world, state.player) do
      nil ->
        can_use(state, self)

      player ->
        {ax, ay, az} = state.at
        {rx, ry} = state.rotation

        if World.distance_sq(self, player) < 36.0 do
          {dx, dy, dz} = {player.x - ax, player.y - ay, player.z - az}

          cond do
            dx * dx + dy * dy + dz * dz > 0.010000000000000002 -> {false, state, self}
            abs(player.pitch - rx) > 5.0 or abs(player.yaw - ry) > 5.0 -> {false, state, self}
            true -> can_use(%{state | rotation: {player.pitch, player.yaw}}, self)
          end
        else
          can_use(
            %{state | at: {player.x, player.y, player.z}, rotation: {player.pitch, player.yaw}},
            self
          )
        end
    end
  end

  def start(state, self) do
    at =
      case World.entity(self.world, state.player) do
        nil -> state.at
        p -> {p.x, p.y, p.z}
      end

    {%{state | at: at, running: true}, self}
  end

  def stop(state, self) do
    {%{state | player: nil, calm: Mth.reduced(100), running: false}, Navigation.stop(self)}
  end

  def tick(state, self) do
    case World.entity(self.world, state.player) do
      nil ->
        {state, self}

      player ->
        self =
          Self.look_at(
            self,
            {player.x, World.eye_y(player), player.z},
            self.facts.max_head_y_rot + 20.0,
            self.facts.max_head_x_rot
          )

        if World.distance_sq(self, player) < state.stop * state.stop do
          {state, Navigation.stop(self)}
        else
          {_, self} = Navigation.move_to_entity(self, player, state.speed)
          {state, self}
        end
    end
  end
end
