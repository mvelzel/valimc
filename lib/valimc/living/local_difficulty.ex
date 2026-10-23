defmodule Valimc.Living.LocalDifficulty do
  @moduledoc """
  The difficulty where something happens (vanilla's `DifficultyInstance`,
  VMC-043b): the world's difficulty scaled up by the world's age, how long
  players spent in the chunk (its inhabited time) and the moon's brightness.
  Mobs read its effective value and special multiplier when they spawn
  (their equipment, enchantments and abilities) and when they hit.
  """
  alias Valimc.Data.Float32

  defstruct difficulty: :normal, effective: 0.0

  @type t :: %__MODULE__{}

  @levels %{peaceful: 0, easy: 1, normal: 2, hard: 3}

  # `DimensionType.MOON_BRIGHTNESS_PER_PHASE`, from the full moon.
  @moon {1.0, 0.75, 0.5, 0.25, 0.0, 0.25, 0.5, 0.75}

  @doc """
  `new DifficultyInstance(base, totalGameTime, localGameTime,
  moonBrightness)`: `difficulty` an atom, the overworld clock's ticks, the
  chunk's inhabited ticks and the moon's brightness, all in float math.
  """
  def new(difficulty, total, inhabited, moon) do
    %__MODULE__{difficulty: difficulty, effective: effective(difficulty, total, inhabited, moon)}
  end

  @doc """
  `ServerLevel.getCurrentDifficultyAt`: at overworld clock `ticks`, whose
  moon phase changes daily, and `inhabited` ticks (0 until chunks keep it).
  """
  def at(difficulty, ticks, inhabited \\ 0),
    do: new(difficulty, ticks, inhabited, elem(@moon, rem(div(max(ticks, 0), 24_000), 8)))

  defp effective(:peaceful, _total, _inhabited, _moon), do: 0.0

  defp effective(difficulty, total, inhabited, moon) do
    hard = difficulty == :hard

    global =
      clamp(Float32.round(Float32.round(Float32.round(total * 1.0) + -72_000.0) / 1_440_000.0))

    global = Float32.round(global * 0.25)
    scale = Float32.round(0.75 + global)

    local = clamp(Float32.round(Float32.round(inhabited * 1.0) / 3_600_000.0))
    local = Float32.round(local * if(hard, do: 1.0, else: 0.75))

    local = Float32.round(local + min(max(Float32.round(moon * 0.25), 0.0), global))
    local = if difficulty == :easy, do: Float32.round(local * 0.5), else: local
    scale = Float32.round(scale + local)
    Float32.round(@levels[difficulty] * scale)
  end

  defp clamp(v), do: min(max(v, 0.0), 1.0)

  @doc "`getSpecialMultiplier`: 0 below an effective 2, 1 above 4."
  def special(%__MODULE__{effective: e}) do
    cond do
      e < 2.0 -> 0.0
      e > 4.0 -> 1.0
      true -> Float32.round(Float32.round(e - 2.0) / 2.0)
    end
  end

  @doc "`getEffectiveDifficulty`."
  def effective(%__MODULE__{effective: e}), do: e
end
