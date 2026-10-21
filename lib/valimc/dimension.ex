defmodule Valimc.Dimension do
  @moduledoc """
  The normal world preset's dimensions (VMC-026b): the overworld, the Nether
  and the End, with their dimension types from `priv/worldgen/dimensions.json`.

  Each dimension is its own world: its own region owners, stores, generation
  scheduler and generator, with region keys `{rx, rz}` unchanged inside it.
  Durable records name regions of the dimension whose store holds them. A
  process works in one dimension at a time, its *context*: region owners, their
  stores and schedulers take theirs when they start, a connection takes its
  player's. World routing (`Valimc.World`, the directory and registries,
  spatial topics, the player index) scopes keys by the caller's context, so
  equal keys of two dimensions never meet. The overworld's scoped keys are the
  plain keys, as before dimensions existed.

  Every dimension's chunks are stored in the overworld's 24 sections (y −64
  to 319); the Nether's and the End's blocks (y 0 to 255) fill sections 4 to
  19 and the rest stays air. Packets send only the dimension's own sections.
  """

  @ids [:overworld, :the_nether, :the_end]
  @context {__MODULE__, :current}

  def ids, do: @ids

  @doc "A dimension's stored code (0 overworld, 1 the Nether, 2 the End)."
  def code(dimension) when dimension in @ids,
    do: Enum.find_index(@ids, &(&1 == dimension))

  @doc "The dimension of a stored code, or nil."
  def of_code(code) when is_integer(code), do: Enum.at(@ids, code)

  @doc """
  An absolute region address across dimensions (`{dimension, key}`, the
  overworld's too), as cross-dimension transfers name their ends (VMC-026c).
  """
  def address?({dimension, {x, z}}) when dimension in @ids, do: is_integer(x) and is_integer(z)
  def address?(_), do: false

  @doc "The calling process's dimension (the overworld unless set)."
  def current, do: Process.get(@context, :overworld)

  @doc "Make `dimension` the calling process's context; returns the previous one."
  def put(dimension) when dimension in @ids, do: Process.put(@context, dimension) || :overworld

  @doc "Run `fun` with `dimension` as the context, restoring the previous one."
  def within(dimension, fun) when dimension in @ids do
    previous = put(dimension)

    try do
      fun.()
    after
      put(previous)
    end
  end

  @doc """
  `fun` bound to the caller's context, for another process (a task) to run:
  the work stays in the dimension that started it.
  """
  def bind(fun) when is_function(fun, 0) do
    dimension = current()
    fn -> within(dimension, fun) end
  end

  def bind(fun) when is_function(fun, 1) do
    dimension = current()
    fn a -> within(dimension, fn -> fun.(a) end) end
  end

  @doc """
  A key scoped by the caller's context (`scope/2`); an address
  (`{dimension, key}`, `address?/1`) names its dimension itself, so a scoped
  key of another dimension is never scoped again (VMC-077o).
  """
  def scope({dimension, {_, _} = key}) when dimension in @ids, do: scope(dimension, key)
  def scope(key), do: scope(current(), key)

  @doc "A routing key of `dimension`: the plain key in the overworld."
  def scope(:overworld, key), do: key
  def scope(dimension, key) when dimension in [:the_nether, :the_end], do: {dimension, key}

  @doc "The dimension and plain key of a scoped key."
  def unscope({dimension, key}) when dimension in [:the_nether, :the_end], do: {dimension, key}
  def unscope(key), do: {:overworld, key}

  @doc "The dimension's resource name, e.g. `minecraft:the_nether`."
  def name(dimension) when dimension in @ids, do: "minecraft:#{dimension}"

  @doc "The dimension of a resource name, or `:error`."
  def parse("minecraft:" <> id), do: parse(id)

  def parse(id) when is_binary(id) do
    case Enum.find(@ids, &(Atom.to_string(&1) == id)) do
      nil -> :error
      dimension -> {:ok, dimension}
    end
  end

  def parse(_), do: :error

  @doc """
  Where `dimension` keeps its files in the world folder `base`: the overworld
  at `base` itself, the others under `dimensions/minecraft/<name>` as 26.3's
  `DimensionType.getStorageFolder` lays them out.
  """
  def storage(nil, _dimension), do: nil
  def storage(base, :overworld), do: base

  def storage(base, dimension) when dimension in [:the_nether, :the_end],
    do: Path.join([base, "dimensions", "minecraft", Atom.to_string(dimension)])

  @doc "The dimension's facts: dimension type, bounds, generator and flags."
  def facts(dimension \\ current()) when dimension in @ids do
    case :persistent_term.get({__MODULE__, :facts}, nil) do
      nil ->
        facts = load_facts()
        :persistent_term.put({__MODULE__, :facts}, facts)
        Map.fetch!(facts, dimension)

      facts ->
        Map.fetch!(facts, dimension)
    end
  end

  @doc "The lowest block Y and the height of the dimension."
  def bounds(dimension \\ current()) do
    %{min_y: min_y, height: height} = facts(dimension)
    {min_y, height}
  end

  @doc "Whether a block Y is inside the dimension's build height."
  def in_height?(y, dimension \\ current()) when is_integer(y) do
    {min_y, height} = bounds(dimension)
    y >= min_y and y < min_y + height
  end

  @doc "The stored sections (of the overworld's 24) the dimension's height spans."
  def section_window(dimension \\ current()) do
    {min_y, height} = bounds(dimension)
    {div(min_y + 64, 16), div(height, 16)}
  end

  defp load_facts do
    json = Valimc.Worldgen.fact("dimensions")

    Map.new(@ids, fn dimension ->
      entry = Map.fetch!(json, name(dimension))

      {dimension,
       %{
         type: entry["type"],
         type_id: Valimc.Protocol.Data.registry_id("minecraft:dimension_type", entry["type"]),
         min_y: entry["min_y"],
         height: entry["height"],
         logical_height: entry["logical_height"],
         sky_light: entry["has_skylight"],
         ceiling: entry["has_ceiling"],
         fixed_time: entry["has_fixed_time"],
         dragon_fight: entry["has_ender_dragon_fight"],
         coordinate_scale: entry["coordinate_scale"],
         noise_settings: entry["noise_settings"],
         biome_source: entry["biome_source"],
         default_clock: entry["default_clock"],
         sea_level: sea_level(entry["noise_settings"])
       }}
    end)
  end

  defp sea_level(settings) do
    Valimc.Worldgen.fact("noise_settings")
    |> Map.fetch!(settings)
    |> Map.fetch!("sea_level")
  end
end
