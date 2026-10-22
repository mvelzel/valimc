defmodule Valimc.Player.PoseQuery do
  @moduledoc """
  A resting player's pose, fluids, powder snow and server tick in one
  physics-kernel call (VMC-077l2), sampled synchronously by its connection on
  its tick; burning, air and rain are applied here as for a move.
  """
  import Bitwise
  alias Valimc.Living.Air
  alias Valimc.Physics.Kernel
  alias Valimc.Data.PlayerPose
  alias Valimc.Player.{Motion, MotionQuery, RainQuery}
  alias Valimc.World.View

  def signature(player) do
    {player.x, player.y, player.z, Map.get(player, :pose, :standing),
     (player.input.shared_flags &&& 2) != 0, player.abilities.flying,
     player.game_mode.current == :spectator, Motion.distance(player),
     Valimc.Player.Kinetics.signature(player)}
  end

  @doc """
  The pose and observations of `player` where it stands, sampled now over
  the published snapshots (or a supplied `view`).
  """
  def run(player, view \\ nil) do
    with {:ok, query} <- Kernel.player_query(player, nil, 0),
         true <- Kernel.bounded?(query) or {:error, :pose_query_limit},
         view = view || View.load(View.new(), query),
         {:ok, r} <- Kernel.player_rest(view, query, player),
         {:ok, tick} <- MotionQuery.kinetics(r.tick),
         {:ok, rain} <- RainQuery.sample({player.x, player.y, player.z}, r.top, view) do
      {:ok,
       %{
         pose: PlayerPose.from_id(r.pose),
         swimming: r.swimming,
         powder_snow: r.powder_snow,
         submerged: Air.submerged?(r.eye_water, r.eye_state),
         eye_water: r.eye_water,
         kinetics: Map.put(tick, :rain, rain),
         ticked: struct!(Motion, r.ticked),
         sources: View.owners(view)
       }}
    end
  end
end
