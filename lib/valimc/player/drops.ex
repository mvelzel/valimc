defmodule Valimc.Player.Drops do
  @moduledoc "A player's drops as entity records, launched as vanilla throws them (`Player.drop`)."
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Entity.ItemDrop
  alias Valimc.Data.PlayerPose
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  @poses [:standing, :crouching, :swimming, :sleeping, :fall_flying, :spin_attack, :dying]
  @height_offset 0.30000001192092896

  def records(player, stacks, kind) when is_list(stacks) and kind in [:directed, :scattered] do
    with {:ok, dimensions} <- PlayerPose.dimensions(Map.get(player, :pose, :standing)),
         {:ok, records} <- build(player, dimensions["eye_height"], stacks, kind) do
      {:ok, World.region_key(World.chunk_key(player.x, player.z)), records}
    else
      _ -> {:error, :invalid_player_drop}
    end
  rescue
    _ -> {:error, :invalid_player_drop}
  end

  def records(_, _, _), do: {:error, :invalid_player_drop}

  defp build(player, eye, stacks, kind) do
    Enum.reduce_while(stacks, {:ok, []}, fn
      %ItemStack{} = stack, {:ok, records} ->
        # Java nextFloat supplies 24 uniform bits.
        draws = for _ <- 1..4, do: (:rand.uniform(16_777_216) - 1) / 16_777_216

        case ItemDrop.launch(player, eye, kind, draws) do
          {:ok, %{position: {x, y, z}, velocity: velocity, pickup_delay: delay}} ->
            record = %{
              uuid: :crypto.strong_rand_bytes(16),
              x: x,
              y: y,
              z: z,
              stack: stack,
              motion: %ItemMotionState{velocity: velocity, pickup_delay: delay}
            }

            {:cont, {:ok, [record | records]}}

          _ ->
            {:halt, {:error, :invalid_player_drop}}
        end

      _, _ ->
        {:halt, {:error, :invalid_player_drop}}
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  @doc "Source inventory authority admits native player eye origins, independent of render pose storage."
  def at_source?(%{x: x, y: y, z: z}, %{x: source_x, y: source_y, z: source_z}) do
    x == source_x and z == source_z and
      Enum.any?(@poses, fn pose ->
        {:ok, dimensions} = PlayerPose.dimensions(pose)
        y == source_y + dimensions["eye_height"] - @height_offset
      end)
  end

  def at_source?(_, _), do: false
end
