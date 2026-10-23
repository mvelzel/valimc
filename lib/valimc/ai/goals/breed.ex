defmodule Valimc.AI.Goals.Breed do
  @moduledoc """
  `BreedGoal`: in love, the nearest mob of its type within eight blocks also
  in love and not panicking is walked to and looked at; after 60 ticks
  (30 updates) within three blocks they breed (`Valimc.Entity.Animal.breed/2`:
  a child, an orb, both parents' age and love).
  """
  use Valimc.AI.Goal

  def new(speed), do: %{speed: speed * 1.0, partner: nil, love: 0}

  def can_use(state, self) do
    if self.data.in_love > 0 do
      {partner, self} = partner(self)
      {partner != nil, %{state | partner: World.ref(partner)}, self}
    else
      {false, state, self}
    end
  end

  defp partner(self) do
    box = World.inflate(Self.box(self), 8.0, 8.0, 8.0)
    conditions = World.conditions(false, range: 8.0, sight: false)
    candidates = World.mobs_in(self, [self.type], box)

    Enum.reduce(candidates, {nil, self}, fn other, {best, self} ->
      {passes, self} = World.test(self, other, conditions)

      fits =
        passes and other.uuid != self.uuid and other.in_love > 0 and not other.panicking and
          (best == nil or World.distance_sq(self, other) < World.distance_sq(self, best))

      {if(fits, do: other, else: best), self}
    end)
  end

  def can_continue(state, self) do
    case World.entity(self.world, state.partner) do
      %{alive: true, in_love: love, panicking: false} when love > 0 ->
        {state.love < 60, state, self}

      _ ->
        {false, state, self}
    end
  end

  def stop(state, self), do: {%{state | partner: nil, love: 0}, self}

  def tick(state, self) do
    case World.entity(self.world, state.partner) do
      nil ->
        {state, self}

      partner ->
        self =
          Self.look_at(
            self,
            {partner.x, World.eye_y(partner), partner.z},
            10.0,
            self.facts.max_head_x_rot
          )

        {_, self} = Navigation.move_to_entity(self, partner, state.speed)
        love = state.love + 1

        self =
          if love >= adjusted(state, 60) and World.distance_sq(self, partner) < 9.0,
            do: Valimc.Entity.Animal.breed(self, partner),
            else: self

        {%{state | love: love}, self}
    end
  end
end
