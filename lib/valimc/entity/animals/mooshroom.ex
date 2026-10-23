defmodule Valimc.Entity.Animals.Mooshroom do
  @moduledoc """
  A mooshroom (`MushroomCow`): a cow's goals, red or brown (`Type`), a
  brown one's suspicious stew effects (`stew_effects`, from a flower it
  ate). A child of two of one colour turns the other once in 1,024
  births, else takes either parent's. Milking, shearing and feeding
  flowers are `interact/3`'s.
  """
  use Valimc.Entity.Animal, type: "minecraft:mooshroom"
  alias Valimc.AI.Self
  alias Valimc.Entity.{Animal, Body}
  alias Valimc.Entity.Animals.{Cow, Interaction}
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @impl true
  def goals, do: Cow.goals("minecraft:mooshroom")

  @impl true
  def defaults, do: %{type: "red", stew: nil}

  @impl true
  def fields(data), do: [{:mooshroom_type, if(data.type == "brown", do: 1, else: 0), 0}]

  @impl true
  def properties(data), do: [{"minecraft:mooshroom/variant", data.type}]

  @bowl ItemTypes.id("minecraft:bowl")
  @shears ItemTypes.id("minecraft:shears")
  @flowers Map.new(Animal.stew_flowers(), fn {name, effects} -> {ItemTypes.id(name), effects} end)

  @doc """
  `MushroomCow.mobInteract`: an adult fills a bowl with stew (a brown one's
  suspicious stew while it holds a flower's effects), shears turn it into
  a cow dropping five of its mushrooms, a brown adult eats a flower for its
  stew's effects (one at a time); else a cow's milking.
  """
  @impl true
  def interact(%Body{data: %{age: age} = data} = body, %{item: %ItemStack{item_id: id}} = request) do
    cond do
      id == @bowl and age >= 0 ->
        {stew, name} =
          case data.stew do
            nil ->
              {ItemStack.new("minecraft:mushroom_stew"), "minecraft:entity.mooshroom.milk"}

            effects ->
              {%{
                 ItemStack.new("minecraft:suspicious_stew")
                 | components: %{"minecraft:suspicious_stew_effects" => effects}
               }, "minecraft:entity.mooshroom.suspicious_milk"}
          end

        {:ok, %{body | data: %{data | stew: nil}},
         Interaction.outcome(
           hand: {:fill, stew},
           events: [Interaction.sound(Animal.sound_id(name), "neutral", 1.0, 1.0)]
         )}

      id == @shears and age >= 0 ->
        shear(body)

      data.type == "brown" and age >= 0 and Map.has_key?(@flowers, id) ->
        if data.stew != nil do
          {:ok, body, Interaction.outcome([])}
        else
          sound =
            Interaction.sound(
              Animal.sound_id("minecraft:entity.mooshroom.eat"),
              "neutral",
              2.0,
              1.0
            )

          {:ok, %{body | data: %{data | stew: @flowers[id]}},
           Interaction.outcome(hand: {:use, 1}, events: [sound])}
        end

      true ->
        Cow.milk(body, request)
    end
  end

  def interact(_body, _request), do: :pass

  # `MushroomCow.shear`: the shear sound, a cow in its place, and its
  # shearing table's mushrooms one by one at its top.
  defp shear(%Body{} = body) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

    {:ok, stacks} =
      Valimc.Blocks.Loot.entity_drops("minecraft:shearing/mooshroom", seed, {0.0, 0.0, 0.0}, %{
        properties: properties(body.data)
      })

    {_, height, _} = Body.dimensions(body)

    drops =
      for stack <- stacks,
          _ <- 1..stack.count//1,
          do: {%{stack | count: 1}, {0.0, height, 0.0}, nil}

    sound =
      Interaction.sound(Animal.sound_id("minecraft:entity.mooshroom.shear"), "player", 1.0, 1.0)

    {:ok, body,
     Interaction.outcome(
       hand: {:wear, 1},
       events: [sound],
       drops: drops,
       convert: Animal.convert(body, "minecraft:cow")
     )}
  end

  @impl true
  def offspring(%Self{} = self, partner) do
    mine = self.data.type
    theirs = partner.data.type

    {flip, self} =
      if mine == theirs do
        {n, self} = Self.int(self, 1024)
        {n == 0, self}
      else
        {false, self}
      end

    if flip do
      {%{type: if(mine == "brown", do: "red", else: "brown")}, self}
    else
      {pick, self} = Self.boolean(self)
      {%{type: if(pick, do: mine, else: theirs)}, self}
    end
  end
end
