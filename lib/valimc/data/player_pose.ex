defmodule Valimc.Data.PlayerPose do
  @moduledoc """
  The player pose catalog (vanilla's default dimensions): ids, dimensions and
  each pose's box, fit box and eye. The physics kernel chooses poses from the
  same catalog (VMC-077l2).
  """
  alias Valimc.Data.Box

  @poses ~w(standing fall_flying sleeping swimming spin_attack crouching long_jumping dying
            croaking using_tongue sitting roaring sniffing emerging digging sliding shooting inhaling)a
  use Valimc.Data.Facts, "physics/player_poses.json"

  unless Enum.map(@facts, & &1["name"]) == Enum.map(@poses, &Atom.to_string/1),
    do: raise("Invalid native player pose catalog")

  @dimensions Map.new(Enum.zip(@poses, @facts))
  @ids Map.new(Enum.zip(@poses, @facts), fn {pose, fact} -> {pose, fact["id"]} end)

  def id(pose), do: Map.fetch!(@ids, pose)

  unless Enum.map(@facts, & &1["id"]) == Enum.to_list(0..(length(@poses) - 1)),
    do: raise("Pose ids are not their catalog order")

  @by_id List.to_tuple(@poses)

  @doc "The pose with catalog id `id`."
  def from_id(id), do: elem(@by_id, id)

  @doc "The catalog's dimensions in id order, as the physics kernel takes them."
  def native_dimensions,
    do: for(f <- @facts, do: {f["width"] * 1.0, f["height"] * 1.0, f["eye_height"] * 1.0})

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
end
