defmodule Valimc.PlayerExperience do
  @moduledoc "Player-owned native float32 XP progress."
  defstruct level: 0, progress: 0.0, total: 0
  @max 2_147_483_647

  def valid?(%__MODULE__{level: level, progress: progress, total: total}),
    do:
      is_integer(level) and level in 0..@max and is_float(progress) and
        progress >= 0.0 and progress < 1.0 and f32(progress) == progress and is_integer(total) and
        total in 0..@max

  def valid?(_), do: false

  def needed(level) when level >= 30, do: 112 + (level - 30) * 9
  def needed(level) when level >= 15, do: 37 + (level - 15) * 5
  def needed(level) when level >= 0, do: 7 + level * 2

  @doc "One denomination unit per pickup. Larger or negative grants require their own admission."
  def give(%__MODULE__{} = xp, amount) when is_integer(amount) and amount in 0..2477 do
    if valid?(xp) and xp.total + amount <= @max do
      progress = f32(xp.progress + f32(amount / needed(xp.level)))
      next = advance(%{xp | progress: progress, total: xp.total + amount})
      if valid?(next), do: {:ok, next}, else: {:error, :experience_limit}
    else
      {:error, :experience_limit}
    end
  end

  def give(_, _), do: {:error, :invalid_experience_grant}

  @doc "Vanilla `Player.giveExperiencePoints` for any int amount (`/experience add`)."
  def add_points(%__MODULE__{} = xp, 0), do: xp

  def add_points(%__MODULE__{} = xp, amount) when is_integer(amount) do
    progress = f32(xp.progress + f32(amount / needed(xp.level)))
    xp = %{xp | progress: progress, total: min(max(xp.total + amount, 0), @max)}
    xp |> lower() |> advance()
  end

  defp lower(%{progress: progress} = xp) when progress < 0.0 do
    remainder = f32(progress * needed(xp.level))

    if xp.level > 0 do
      xp = add_levels(xp, -1)
      lower(%{xp | progress: f32(1.0 + f32(remainder / needed(xp.level)))})
    else
      lower(%{add_levels(xp, -1) | progress: 0.0})
    end
  end

  defp lower(xp), do: xp

  @doc "Vanilla `giveExperienceLevels`: saturating; below zero everything resets."
  def add_levels(%__MODULE__{} = xp, 0), do: xp

  def add_levels(%__MODULE__{} = xp, levels) when is_integer(levels) do
    level = min(max(xp.level + levels, -2_147_483_648), @max)

    if level < 0,
      do: %{xp | level: 0, progress: 0.0, total: 0},
      else: %{xp | level: level}
  end

  @doc "Vanilla `setExperiencePoints`: `:error` when not below the current level's need."
  def set_points(%__MODULE__{} = xp, amount) when is_integer(amount) do
    limit = needed(xp.level)

    if amount < limit do
      top = f32((limit - 1.0) / limit)
      {:ok, %{xp | progress: f32(amount / limit) |> max(0.0) |> min(top)}}
    else
      :error
    end
  end

  def set_levels(%__MODULE__{} = xp, level) when is_integer(level) and level >= 0,
    do: %{xp | level: level}

  @doc "`/experience query points`: progress times the current level's need, floored."
  def points(%__MODULE__{} = xp), do: floor(f32(xp.progress * needed(xp.level)))

  def encode(xp) do
    if valid?(xp),
      do: {:ok, <<xp.level::32, xp.progress::float-32, xp.total::32>>},
      else: {:error, :invalid_experience}
  end

  def decode(<<level::32, progress::float-32, total::32>>) do
    xp = %__MODULE__{level: level, progress: progress, total: total}
    if valid?(xp), do: {:ok, xp}, else: {:error, :invalid_experience}
  end

  def decode(_), do: {:error, :invalid_experience}

  defp advance(%{progress: progress} = xp) when progress >= 1.0 do
    remainder = f32(f32(progress - 1.0) * needed(xp.level))
    xp = add_levels(xp, 1)
    advance(%{xp | progress: f32(remainder / needed(xp.level))})
  end

  defp advance(xp), do: xp

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
