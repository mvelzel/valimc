defmodule Valimc.Player.Drops do
  @moduledoc "A player's drops as entity records, launched as vanilla throws them (`Player.drop`)."
  alias Valimc.Data.Grid
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Entity.ItemDrop
  alias Valimc.Data.PlayerPose
  alias Valimc.Protocol.ItemStack

  def records(player, stacks, kind) when is_list(stacks) and kind in [:directed, :scattered] do
    with {:ok, dimensions} <- PlayerPose.dimensions(Map.get(player, :pose, :standing)),
         {:ok, records} <- build(player, dimensions["eye_height"], stacks, kind) do
      {:ok, Grid.region_key(Grid.chunk_key(player.x, player.z)), records}
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
end
