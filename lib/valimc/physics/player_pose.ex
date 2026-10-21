defmodule Valimc.Physics.PlayerPose do
  @moduledoc "Native default dimensions and pure supplied-fit selection; live authority is separate."
  alias Valimc.Physics.Box

  defstruct sleeping: false,
            swimming: false,
            fall_flying: false,
            spin_attack: false,
            shift: false,
            flying: false,
            spectator: false,
            passenger: false

  @poses ~w(standing fall_flying sleeping swimming spin_attack crouching long_jumping dying
            croaking using_tongue sitting roaring sniffing emerging digging sliding shooting inhaling)a
  @intent_keys [
    :sleeping,
    :swimming,
    :fall_flying,
    :spin_attack,
    :shift,
    :flying,
    :spectator,
    :passenger
  ]
  use Valimc.Facts, "physics/player_poses.json"

  unless Enum.map(@facts, & &1["name"]) == Enum.map(@poses, &Atom.to_string/1),
    do: raise("Invalid native player pose catalog")

  @dimensions Map.new(Enum.zip(@poses, @facts))
  @ids Map.new(Enum.zip(@poses, @facts), fn {pose, fact} -> {pose, fact["id"]} end)

  def id(pose), do: Map.fetch!(@ids, pose)

  def dimensions(pose) do
    case Map.fetch(@dimensions, pose) do
      {:ok, dimensions} -> {:ok, dimensions}
      :error -> {:error, :unknown_pose}
    end
  end

  def geometry(pose, {x, y, z})
      when is_number(x) and abs(x) <= 29_999_984 and is_number(z) and abs(z) <= 29_999_984 and
             is_number(y) and abs(y) <= 1_000_000 do
    with {:ok, dimensions} <- dimensions(pose) do
      half = dimensions["width"] / 2
      top = y + dimensions["height"]
      box = Box.new({x - half, y, z - half, x + half, top, z + half})
      {x0, y0, z0, x1, y1, z1} = box

      fit =
        Box.new({x0 + 1.0e-7, y0 + 1.0e-7, z0 + 1.0e-7, x1 - 1.0e-7, y1 - 1.0e-7, z1 - 1.0e-7})

      {:ok, %{box: box, fit_box: fit, eye: {x * 1.0, y + dimensions["eye_height"], z * 1.0}}}
    end
  end

  def geometry(_, _), do: {:error, :invalid_pose_position}

  def select(current, %__MODULE__{} = intent, fits)
      when map_size(intent) == 9 and is_map(fits) and map_size(fits) <= 18 do
    valid =
      current in @poses and Enum.all?(@intent_keys, &is_boolean(Map.get(intent, &1)))

    valid_fits = Enum.all?(fits, fn {pose, fits?} -> pose in @poses and is_boolean(fits?) end)

    if valid and valid_fits do
      choose(current, intent, fits)
    else
      {:error, :invalid_pose_observations}
    end
  end

  def select(_, _, _), do: {:error, :invalid_pose_observations}

  defp choose(current, intent, fits) do
    case Map.fetch(fits, :swimming) do
      :error -> {:error, {:missing_fit, :swimming}}
      {:ok, false} -> {:ok, current, [:swimming]}
      {:ok, true} -> choose_desired(desired(intent), intent, fits)
    end
  end

  defp choose_desired(desired, %{spectator: spectator, passenger: passenger}, _fits)
       when spectator or passenger,
       do: {:ok, desired, [:swimming]}

  defp choose_desired(desired, _intent, fits) do
    case Map.fetch(fits, desired) do
      :error ->
        {:error, {:missing_fit, desired}}

      {:ok, true} ->
        {:ok, desired, [:swimming, desired]}

      {:ok, false} ->
        case Map.fetch(fits, :crouching) do
          :error -> {:error, {:missing_fit, :crouching}}
          {:ok, true} -> {:ok, :crouching, [:swimming, desired, :crouching]}
          {:ok, false} -> {:ok, :swimming, [:swimming, desired, :crouching]}
        end
    end
  end

  defp desired(intent) do
    cond do
      intent.sleeping -> :sleeping
      intent.swimming -> :swimming
      intent.fall_flying -> :fall_flying
      intent.spin_attack -> :spin_attack
      intent.shift and not intent.flying -> :crouching
      true -> :standing
    end
  end
end
