defmodule Valimc.World.Border do
  @moduledoc """
  One dimension's world border (VMC-027b), vanilla's `WorldBorder`: centre,
  damage per block, safe zone, warning distance and time, the absolute size
  limit, and a stationary or moving extent. A moving extent steps once per game
  tick from its start size towards its target; its bounds use the previous
  step's size, as vanilla's do at partial tick 0.

  Pure state owned by the environment owner (`Valimc.World.Clock`), which ticks,
  persists and publishes it. `revisions` are not saved: each change stamps its
  kind with a fresh number, so observers resend exactly the packets vanilla's
  border listeners send.
  """
  alias Valimc.Physics.BorderSnapshot

  @max_size 59_999_968.0
  @max_center 29_999_984.0
  @absolute_max 29_999_984
  # The player's half width, `0.6F / 2.0F` widened to a double.
  @player_half_width 0.30000001192092896
  @corner_epsilon 9.999999747378752e-6
  @int_min -2_147_483_648
  @int_max 2_147_483_647

  defstruct center_x: 0.0,
            center_z: 0.0,
            damage_per_block: 0.2,
            safe_zone: 5.0,
            warning_blocks: 5,
            warning_time: 300,
            absolute_max: @absolute_max,
            extent: {:static, @max_size},
            revisions: %{center: 0, size: 0, warning_time: 0, warning_blocks: 0},
            size_change: :set

  def max_size, do: @max_size
  def max_center, do: @max_center

  @doc "Vanilla's default border (`WorldBorder.Settings.DEFAULT`)."
  def new, do: %__MODULE__{}

  # ---- extent ----

  @doc "The current size (`getSize`)."
  def size(%__MODULE__{extent: {:static, size}}), do: size
  def size(%__MODULE__{extent: %{size: size}}), do: size

  @doc "The size the border is moving to, or its size when stationary (`getLerpTarget`)."
  def lerp_target(%__MODULE__{extent: {:static, size}}), do: size
  def lerp_target(%__MODULE__{extent: %{to: to}}), do: to

  @doc "Remaining ticks of a moving border, 0 when stationary (`getLerpTime`)."
  def lerp_time(%__MODULE__{extent: {:static, _}}), do: 0
  def lerp_time(%__MODULE__{extent: %{progress: progress}}), do: progress

  @doc "Blocks per tick of a moving border (`getLerpSpeed`)."
  def lerp_speed(%__MODULE__{extent: {:static, _}}), do: 0.0

  def lerp_speed(%__MODULE__{extent: %{from: from, to: to, begin: begin, end: finish}}),
    do: abs(from - to) / (finish - begin)

  def status(%__MODULE__{extent: {:static, _}}), do: :stationary
  def status(%__MODULE__{extent: %{from: from, to: to}}) when to < from, do: :shrinking
  def status(%__MODULE__{}), do: :growing

  # The size the bounds use: a moving border's previous step.
  defp bounds_size(%__MODULE__{extent: {:static, size}}), do: size
  defp bounds_size(%__MODULE__{extent: %{previous: previous}}), do: previous

  @doc "`{min_x, min_z, max_x, max_z}` at partial tick 0, clamped to the absolute limit."
  def bounds(%__MODULE__{center_x: x, center_z: z, absolute_max: m} = border) do
    half = bounds_size(border) / 2.0
    limit = m * 1.0

    {clamp(x - half, limit), clamp(z - half, limit), clamp(x + half, limit),
     clamp(z + half, limit)}
  end

  # `Mth.clamp(value, -limit, limit)`.
  defp clamp(value, limit) when value < -limit, do: -limit
  defp clamp(value, limit), do: min(value, limit)

  @doc "The collision and proximity observation of the current bounds."
  def snapshot(%__MODULE__{} = border) do
    %BorderSnapshot{
      center_x: border.center_x,
      center_z: border.center_z,
      diameter: bounds_size(border),
      absolute_max: border.absolute_max
    }
  end

  @doc "Point containment (`isWithinBounds(x, z)`)."
  def within?(border, x, z) do
    {a, c, b, d} = bounds(border)
    x >= a and x < b and z >= c and z < d
  end

  @doc """
  Whether players may interact with the block at `{x, y, z}`
  (`ServerLevel.mayInteract`: the block's corner inside the border), from the
  published physics view.
  """
  def interactable?(%{snapshot: snapshot}, {x, _y, z}) do
    {:ok, inside} = BorderSnapshot.contains?(snapshot, {x * 1.0, z * 1.0})
    inside
  end

  @doc "Distance from a point to the nearest edge, negative outside (`getDistanceToBorder`)."
  def distance(border, x, z) do
    {a, c, b, d} = bounds(border)
    min(min(min(x - a, b - x), z - c), d - z)
  end

  @doc """
  One game tick (`WorldBorder.tick`): a moving extent steps once and becomes
  stationary at its target when no ticks remain.
  """
  def tick(%__MODULE__{extent: {:static, _}} = border), do: border

  def tick(%__MODULE__{extent: extent} = border) do
    progress = extent.progress - 1
    stepped = %{extent | progress: progress, previous: extent.size}
    stepped = %{stepped | size: calculate(stepped)}

    %{border | extent: if(progress <= 0, do: {:static, extent.to}, else: stepped)}
  end

  defp moving(from, to, ticks, game_time) do
    extent = %{
      from: from,
      to: to,
      duration: ticks * 1.0,
      progress: ticks,
      begin: game_time,
      end: game_time + ticks,
      size: 0.0,
      previous: 0.0
    }

    size = calculate(extent)
    %{extent | size: size, previous: size}
  end

  # `MovingBorderExtent.calculateSize`; a zero duration has reached its target.
  defp calculate(%{duration: duration} = extent) when duration == 0, do: extent.to

  defp calculate(%{from: from, to: to, duration: duration, progress: progress}) do
    done = (duration - progress) / duration
    if done < 1.0, do: from + done * (to - from), else: to
  end

  # ---- changes (each stamps the listener event vanilla broadcasts) ----

  def set_center(border, x, z),
    do: stamp(%{border | center_x: x * 1.0, center_z: z * 1.0}, :center)

  def set_size(border, size),
    do: stamp(%{border | extent: {:static, size * 1.0}, size_change: :set}, :size)

  @doc "`lerpSizeBetween`: equal sizes give a stationary extent, still announced as a lerp."
  def lerp(border, from, to, ticks, game_time) when is_integer(ticks) and is_integer(game_time) do
    extent =
      if from == to, do: {:static, to * 1.0}, else: moving(from * 1.0, to * 1.0, ticks, game_time)

    stamp(%{border | extent: extent, size_change: :lerp}, :size)
  end

  def set_damage_per_block(border, value), do: %{border | damage_per_block: value * 1.0}
  def set_safe_zone(border, value), do: %{border | safe_zone: value * 1.0}
  def set_warning_time(border, ticks), do: stamp(%{border | warning_time: ticks}, :warning_time)

  def set_warning_blocks(border, blocks),
    do: stamp(%{border | warning_blocks: blocks}, :warning_blocks)

  defp stamp(border, kind),
    do: %{
      border
      | revisions: Map.put(border.revisions, kind, System.unique_integer([:positive, :monotonic]))
    }

  # ---- `/worldborder` (VMC-027c), atomic in the owner ----

  @doc """
  Apply one `/worldborder` change as `WorldBorderCommand` does, with its
  failure checks against the current state: `{:ok, border, result}` or
  `{:error, reason}`. `add` without a time is immediate; with a time it adds
  to the remaining ticks of a moving border. Sizes and centres are doubles, damage values floats
  widened to doubles, times and distances ints.
  """
  def command(border, {:add, distance, nil}, game_time),
    do: resize(border, size(border) + distance, 0, game_time)

  def command(border, {:add, distance, ticks}, game_time),
    do: resize(border, size(border) + distance, lerp_time(border) + ticks, game_time)

  def command(border, {:set, distance, ticks}, game_time),
    do: resize(border, distance, ticks, game_time)

  def command(border, {:center, x, z}, _game_time) do
    cond do
      border.center_x == x and border.center_z == z -> {:error, :same_center}
      abs(x) > @max_center or abs(z) > @max_center -> {:error, :too_far_out}
      true -> {:ok, set_center(border, x, z), nil}
    end
  end

  def command(border, {:damage_amount, value}, _game_time) do
    if border.damage_per_block == value,
      do: {:error, :same_damage_amount},
      else: {:ok, set_damage_per_block(border, value), nil}
  end

  def command(border, {:damage_buffer, value}, _game_time) do
    if border.safe_zone == value,
      do: {:error, :same_damage_buffer},
      else: {:ok, set_safe_zone(border, value), nil}
  end

  def command(border, {:warning_time, ticks}, _game_time) do
    if border.warning_time == ticks,
      do: {:error, :same_warning_time},
      else: {:ok, set_warning_time(border, ticks), nil}
  end

  def command(border, {:warning_distance, blocks}, _game_time) do
    if border.warning_blocks == blocks,
      do: {:error, :same_warning_distance},
      else: {:ok, set_warning_blocks(border, blocks), nil}
  end

  def command(_, _, _), do: {:error, :invalid_border_change}

  defp resize(border, distance, ticks, game_time) do
    current = size(border)

    cond do
      current == distance ->
        {:error, :same_size}

      distance < 1.0 ->
        {:error, :too_small}

      distance > @max_size ->
        {:error, :too_big}

      ticks > 0 ->
        {:ok, lerp(border, current, distance, ticks, game_time), {current, distance, ticks}}

      true ->
        {:ok, set_size(border, distance), {current, distance, ticks}}
    end
  end

  # ---- damage outside (`LivingEntity.baseTick`) ----

  @doc """
  Damage for a player at `{x, z}` this tick: none while the player's box is
  inside, otherwise `max(1, floor(-(distance + safe zone) * damage per block))`
  once the centre is beyond the safe zone and the damage per block is
  positive. `physics/1` is the published input.
  """
  def damage(%{snapshot: snapshot, safe_zone: safe, damage_per_block: per_block}, x, z) do
    if box_inside?(snapshot, x, z) do
      0.0
    else
      {:ok, distance} = BorderSnapshot.distance(snapshot, {x, z})
      dist = distance + safe

      if dist < 0.0 and per_block > 0.0 do
        # `hurtServer` takes a float.
        <<amount::float-32>> = <<max(1, java_int(Float.floor(-dist * per_block)))::float-32>>
        amount
      else
        0.0
      end
    end
  end

  defp box_inside?(snapshot, x, z) do
    {:ok, {a, c, b, d}} = BorderSnapshot.bounds(snapshot)
    within = fn px, pz -> px >= a and px < b and pz >= c and pz < d end
    w = @player_half_width

    within.(x - w, z - w) and within.(x + w - @corner_epsilon, z + w - @corner_epsilon)
  end

  # `(int)` of a double: saturating.
  defp java_int(value) when value >= @int_max, do: @int_max
  defp java_int(value) when value <= @int_min, do: @int_min
  defp java_int(value), do: trunc(value)

  @doc "What collision and damage readers need, published with each change."
  def physics(border),
    do: %{
      snapshot: snapshot(border),
      safe_zone: border.safe_zone,
      damage_per_block: border.damage_per_block
    }

  # ---- persistence (`WorldBorder.Settings`) ----

  @settings_bytes 64

  @doc "The saved settings: centre, damage, safe zone, warnings, size, remaining lerp ticks and target."
  def encode(%__MODULE__{} = border) do
    <<border.center_x::float-64, border.center_z::float-64, border.damage_per_block::float-64,
      border.safe_zone::float-64, border.warning_blocks::signed-32,
      border.warning_time::signed-32, size(border)::float-64, lerp_time(border)::signed-64,
      lerp_target(border)::float-64>>
  end

  @doc """
  A border from saved settings at `game_time` (`applyInitialSettings`): a
  remaining lerp continues from the saved size.
  """
  def decode(
        <<x::float-64, z::float-64, damage::float-64, safe::float-64, blocks::signed-32,
          time::signed-32, size::float-64, ticks::signed-64, target::float-64>>,
        game_time
      )
      when abs(x) <= @max_center and abs(z) <= @max_center and size >= 0 and size <= @max_size and
             target >= 0 and target <= @max_size and ticks >= 0 and ticks <= 0x7FFFFFFFFFFFFFFF do
    border = %__MODULE__{
      center_x: x,
      center_z: z,
      damage_per_block: damage,
      safe_zone: safe,
      warning_blocks: blocks,
      warning_time: time
    }

    border =
      if ticks > 0,
        do: lerp(border, size, target, ticks, game_time),
        else: set_size(border, size)

    {:ok, %{border | revisions: %__MODULE__{}.revisions, size_change: :set}}
  end

  def decode(_, _), do: {:error, :invalid_border_settings}

  def settings_bytes, do: @settings_bytes

  def valid?(%__MODULE__{} = border) do
    is_float(border.center_x) and is_float(border.center_z) and
      abs(border.center_x) <= @max_center and
      abs(border.center_z) <= @max_center and is_float(border.damage_per_block) and
      is_float(border.safe_zone) and int?(border.warning_blocks) and int?(border.warning_time) and
      is_integer(border.absolute_max) and border.absolute_max in 0..@absolute_max and
      extent?(border.extent)
  end

  def valid?(_), do: false

  defp extent?({:static, size}), do: is_float(size) and size >= 0 and size <= @max_size

  defp extent?(%{from: from, to: to, progress: progress, size: size, previous: previous}),
    do:
      Enum.all?([from, to, size, previous], &(is_float(&1) and &1 >= 0 and &1 <= @max_size)) and
        is_integer(progress) and progress > 0

  defp extent?(_), do: false

  defp int?(value), do: is_integer(value) and value >= @int_min and value <= @int_max
end
