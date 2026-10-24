defmodule Valimc.AI.Mobs.TropicalFish do
  @moduledoc """
  `TropicalFish`: a schooling fish (`Mobs.Fish`) of one of 22 common
  variants (nine in ten spawns, a school sharing one), or of any pattern
  and two dye colours, which then schools with none. The variant is packed
  as vanilla packs it: the pattern's id, the base colour's at bit 16, the
  pattern colour's at bit 24.
  """
  @behaviour Valimc.AI.Kind
  import Bitwise
  alias Valimc.AI.{Mobs.Fish, Random, Self}

  @type_name "minecraft:tropical_fish"

  # Patterns in vanilla's order: `{base, index}` (small 0, large 1).
  @patterns %{
    kob: {0, 0},
    sunstreak: {0, 1},
    snooper: {0, 2},
    dasher: {0, 3},
    brinely: {0, 4},
    spotty: {0, 5},
    flopper: {1, 0},
    stripey: {1, 1},
    glitter: {1, 2},
    blockfish: {1, 3},
    betty: {1, 4},
    clayfish: {1, 5}
  }
  @order [
    :kob,
    :sunstreak,
    :snooper,
    :dasher,
    :brinely,
    :spotty,
    :flopper,
    :stripey,
    :glitter,
    :blockfish,
    :betty,
    :clayfish
  ]
  @colors %{
    white: 0,
    orange: 1,
    gray: 7,
    light_blue: 3,
    yellow: 4,
    lime: 5,
    pink: 6,
    cyan: 9,
    purple: 10,
    blue: 11,
    red: 14
  }
  @common [
    {:stripey, :orange, :gray},
    {:flopper, :gray, :gray},
    {:flopper, :gray, :blue},
    {:clayfish, :white, :gray},
    {:sunstreak, :blue, :gray},
    {:kob, :orange, :white},
    {:spotty, :pink, :light_blue},
    {:blockfish, :purple, :yellow},
    {:clayfish, :white, :red},
    {:spotty, :white, :yellow},
    {:glitter, :white, :gray},
    {:clayfish, :white, :orange},
    {:dasher, :cyan, :pink},
    {:brinely, :lime, :light_blue},
    {:betty, :red, :white},
    {:snooper, :gray, :red},
    {:blockfish, :red, :white},
    {:flopper, :white, :yellow},
    {:kob, :red, :white},
    {:sunstreak, :gray, :white},
    {:dasher, :cyan, :yellow},
    {:flopper, :yellow, :yellow}
  ]

  @doc "`packVariant(pattern, base colour, pattern colour)` (colours by dye id)."
  def pack(pattern, base, color) do
    {kind, index} = @patterns[pattern]

    bor(
      bor(band(bor(kind, index <<< 8), 0xFFFF), band(base, 0xFF) <<< 16),
      band(color, 0xFF) <<< 24
    )
  end

  # Kob, white on white.
  @default 0
  @common_packed Enum.map(@common, fn {p, b, c} ->
                   {kind, index} = @patterns[p]
                   kind + (index <<< 8) + (@colors[b] <<< 16) + (@colors[c] <<< 24)
                 end)
                 |> List.to_tuple()

  @impl true
  def types, do: [@type_name]

  @doc "A dying one still runs its own tick (it flops)."
  @impl true
  def dying?, do: true

  @impl true
  def goals(type), do: {Fish.fish_goals() ++ Fish.school_goals(type), []}

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
  defdelegate after_tick(self), to: Fish

  @impl true
  def data(_type), do: %{from_bucket: false, variant: @default}

  @impl true
  def values(%{data: data}),
    do: [
      {:fish_from_bucket, data.from_bucket, false},
      {:tropical_fish_variant, data.variant, @default}
    ]

  @doc """
  `finalizeSpawn` from the level's random: a common variant nine times in
  ten, else any pattern and colours (`Util.getRandom` draws).
  """
  @impl true
  def finalize(%Self{} = self, reason) do
    self = Valimc.AI.Spawn.mob(self, reason)
    {f, random} = Random.float(self.world.random)

    spawn_variant(
      %{self | world: %{self.world | random: random}},
      f < Valimc.Data.Float32.round(0.9)
    )
  end

  @doc "The variant chosen after the owning spawner's school decision."
  def spawn_variant(%Self{world: world, data: data} = self, school) do
    random = world.random

    {variant, random} =
      if school do
        {n, random} = Random.int(random, tuple_size(@common_packed))
        {elem(@common_packed, n), random}
      else
        {p, random} = Random.int(random, length(@order))
        {b, random} = Random.int(random, 16)
        {c, random} = Random.int(random, 16)
        {pack(Enum.at(@order, p), b, c), random}
      end

    %{self | world: %{world | random: random}, data: %{data | variant: variant}}
  end
end
