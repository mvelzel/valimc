defmodule Valimc.Entity.Animals.Sheep do
  @moduledoc """
  A sheep (`Sheep`): its goals (grazing, `EatBlockGoal`), its wool's colour
  and whether it is sheared (`DATA_WOOL_ID`: the colour in the low four
  bits, sheared bit 4). Eating grass grows its wool back and a lamb older
  (`ate`). A lamb's colour is its parents' crafted mix (`DyeColor.
  getMixedColor`), else either's, drawn from the level's random. Shearing
  and dyeing are `interact/3`'s.
  """
  use Valimc.Entity.Animal, type: "minecraft:sheep"
  import Bitwise
  alias Valimc.AI.{Goals, Random, Self}
  alias Valimc.Data.Float32
  alias Valimc.Entity.{Animal, Body}
  alias Valimc.Entity.Animals.Interaction
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @colors ~w(white orange magenta light_blue yellow lime pink gray light_gray cyan purple blue
             brown green red black)

  @doc "The dye colours by id (`DyeColor`)."
  def colors, do: @colors

  # `findColorMixInRecipes`: the dye a crafting grid of the two dyes makes.
  @mixes (for {a, i} <- Enum.with_index(@colors), {b, j} <- Enum.with_index(@colors), into: %{} do
            grid = [
              %ItemStack{item_id: ItemTypes.id("minecraft:#{a}_dye")},
              %ItemStack{item_id: ItemTypes.id("minecraft:#{b}_dye")},
              nil,
              nil
            ]

            dyes = Enum.map(@colors, &ItemTypes.id("minecraft:#{&1}_dye"))

            mixed =
              case Valimc.Menus.Crafting.result(grid) do
                {:ok, %ItemStack{item_id: id}} -> Enum.find_index(dyes, &(&1 == id))
                _ -> nil
              end

            {{i, j}, mixed}
          end)

  @impl true
  def goals do
    {[
       {0, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "PanicGoal", Goals.Panic, [:move], Goals.Panic.new(1.25)},
       {2, "BreedGoal", Goals.Breed, [:move, :look], Goals.Breed.new(1.0)},
       {3, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.1, &Animal.food?("minecraft:sheep", &1), false)},
       {4, "FollowParentGoal", Goals.FollowParent, [], Goals.FollowParent.new(1.1)},
       {5, "EatBlockGoal", Goals.EatBlock, [:move, :look, :jump], Goals.EatBlock.new()},
       {6, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)},
       {7, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(6.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ], []}
  end

  @impl true
  def defaults, do: %{color: 0, sheared: false}

  @impl true
  def fields(data), do: [{:sheep_wool, wool(data), 0}]

  @impl true
  def properties(data),
    do: [
      {"minecraft:sheep/color", Enum.at(@colors, data.color)},
      {"sheep/sheared", to_string(data.sheared)}
    ]

  @shears ItemTypes.id("minecraft:shears")
  @dyes Map.new(Enum.with_index(@colors), fn {color, i} ->
          {ItemTypes.id("minecraft:#{color}_dye"), i}
        end)

  @doc """
  `Sheep.mobInteract`: shears shear an adult with its wool (one to three of
  its colour, each launched a little from the sheep's random) and the arm
  swings; shears on a sheep not ready do nothing more.
  """
  @impl true
  def interact(%Body{data: data} = body, %{item: %ItemStack{item_id: @shears}}) do
    if data.sheared or data.age < 0, do: :consume, else: shear(body)
  end

  def interact(_body, _request), do: :pass

  defp shear(%Body{data: data} = body) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

    {:ok, stacks} =
      Valimc.Blocks.Loot.entity_drops("minecraft:shearing/sheep", seed, {0.0, 0.0, 0.0}, %{
        properties: properties(data)
      })

    {drops, body} =
      for stack <- stacks, _ <- 1..stack.count//1, reduce: {[], body} do
        {drops, body} ->
          {dx, body} = Interaction.spread(body, 0.1)
          {f, body} = Interaction.draw(body, &Valimc.AI.Random.float/1)
          dy = Float32.round(f * Float32.round(0.05))
          {dz, body} = Interaction.spread(body, 0.1)
          {drops ++ [{%{stack | count: 1}, {0.0, 1.0, 0.0}, {:add, {dx, dy, dz}}}], body}
      end

    sound = Interaction.sound(Animal.sound_id("minecraft:entity.sheep.shear"), "player", 1.0, 1.0)

    {:ok, %{body | data: %{data | sheared: true}},
     Interaction.outcome(hand: {:wear, 1}, swing: true, events: [sound], drops: drops)}
  end

  @doc """
  `DyeItem.interactLivingEntity`: a dye of another colour dyes a living
  sheep that is not sheared; the others hear it at the sheep.
  """
  @impl true
  def use_item(%Body{data: data} = body, %{item: %ItemStack{item_id: id}}) do
    case @dyes[id] do
      color when color != nil and color != data.color and not data.sheared ->
        sound = {Animal.sound_id("minecraft:item.dye.use"), "player", 1.0, 1.0, :animal}

        {:ok, %{body | data: %{data | color: color}},
         Interaction.outcome(hand: {:use, 1}, others: sound)}

      _ ->
        :pass
    end
  end

  def use_item(_body, _request), do: :pass

  @doc "`DATA_WOOL_ID`."
  def wool(%{color: color, sheared: sheared}), do: if(sheared, do: 16, else: 0) ||| color

  @impl true
  def offspring(%Self{} = self, partner) do
    {a, b} = {self.data.color, partner.data.color}

    case @mixes[{a, b}] do
      nil ->
        {pick, random} = Random.boolean(self.world.random)
        {%{color: if(pick, do: a, else: b)}, %{self | world: %{self.world | random: random}}}

      mixed ->
        {%{color: mixed}, self}
    end
  end

  # `SheepColorSpawnRules`: a climate's weighted colours (100 in all), its
  # common one a weighted 499 to a pink 1.
  @climates %{
    temperate: {[black: 5, gray: 5, light_gray: 5, brown: 3], :white},
    warm: {[gray: 5, light_gray: 5, white: 5, black: 3], :brown},
    cold: {[light_gray: 5, gray: 5, white: 5, brown: 3], :black}
  }

  @doc """
  `finalizeSpawn`'s colour (`getRandomSheepColor`): the biome's climate's
  weighted colours, from the level's random.
  """
  @impl true
  def spawn_part(%Self{} = self, _reason) do
    biome = Animal.biome(self)

    climate =
      cond do
        Animal.biome_in?(biome, "minecraft:spawns_warm_variant_farm_animals") -> :warm
        Animal.biome_in?(biome, "minecraft:spawns_cold_variant_farm_animals") -> :cold
        true -> :temperate
      end

    {singles, common} = @climates[climate]
    {n, self} = Valimc.AI.Spawn.level_int(self, 100)

    {color, self} =
      case pick(singles, n) do
        nil ->
          {m, self} = Valimc.AI.Spawn.level_int(self, 500)
          {if(m < 499, do: common, else: :pink), self}

        color ->
          {color, self}
      end

    %{self | data: %{self.data | color: color_id(color)}}
  end

  # The weighted entry `n` falls on, or nil for the last (the common colour).
  defp pick([], _n), do: nil
  defp pick([{color, weight} | _], n) when n < weight, do: color
  defp pick([{_, weight} | rest], n), do: pick(rest, n - weight)

  defp color_id(color), do: Enum.find_index(@colors, &(&1 == Atom.to_string(color)))

  @doc "`Sheep.ate`: its wool grows back, a lamb grows a minute older."
  @impl true
  def ate(%Self{data: data} = self) do
    data = %{data | sheared: false}

    data =
      if Animal.can_age_up?(data),
        do: elem(Animal.age_up(data, 60, false, 0), 0),
        else: data

    %{self | data: data}
  end
end
