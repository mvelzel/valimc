defmodule Valimc.Player.MotionQuery do
  @moduledoc """
  One move packet's validation and observations in one physics-kernel call
  (VMC-077l2), run synchronously by the player's connection over published
  snapshots: the collision with step-up, vanilla's "moved wrongly" and
  new-collision rules, the pose, fluids, powder snow, landing, exhaustion and
  the server's own tick. The living rules stay here: burning plans from the
  tick's contacts, landing damage from the landing block, air from the eye's
  block and rain from the column. Only the connection applies the result.
  """
  import Bitwise
  alias Valimc.Living.{Air, Burning}
  alias Valimc.Data.PlayerPose
  alias Valimc.Living.Landing
  alias Valimc.Player.{Motion, RainQuery}
  alias Valimc.World.View

  @doc """
  Validate a move of `player` to `target` (`%{x, y, z}`) with packet `flags`,
  over the published snapshots (or a supplied `view`).
  """
  def run(player, target, flags \\ 0, view \\ nil) do
    # The kernel refuses a box past its `QUERY_CELLS`: only a forged packet's
    # cost; the speed check bounds a vanilla client's move first.
    with {:ok, query} <- Valimc.Player.Kinetics.player_query(player, target, flags),
         view = view || View.load(View.new(), query),
         {:ok, r} <- Valimc.Player.Kinetics.player_move(view, query, player, target, flags),
         {:ok, tick} <- kinetics(r.tick),
         {:ok, rain} <- RainQuery.sample({target.x, target.y, target.z}, r.top, view, player),
         {:ok, landing} <- landing(r.landing, player) do
      {:ok,
       %{
         accepted: r.accepted,
         pose: PlayerPose.from_id(r.pose),
         swimming: r.swimming,
         moved: r.moved,
         powder_snow: r.powder_snow,
         submerged: Air.submerged?(r.eye_water, r.eye_state),
         eye_water: r.eye_water,
         exhaustion: r.exhaustion,
         kinetics: %{packet: r.packet, tick: Map.put(tick, :rain, rain)},
         landing: landing,
         motion: struct!(Motion, r.motion),
         ticked: struct!(Motion, r.ticked),
         sources: View.owners(view)
       }}
    end
  end

  @doc false
  # A tick's kinetics with its contacts as the burning rules order them:
  # immediate damage first, then the planned fire and fluid operations.
  def kinetics(%{fire_contacts: fires} = tick) do
    with {:ok, operations} <- Burning.plan(fires.steps) do
      immediate = for {source, amount} <- fires.immediate, do: {:damage, source, amount}
      {:ok, %{tick | fire_contacts: %{operations: immediate ++ operations, active: fires.active}}}
    end
  end

  defp landing(nil, _player), do: {:ok, nil}

  defp landing({state, distance}, player),
    do: Landing.call(state, distance, (player.input.shared_flags &&& 2) != 0)
end
