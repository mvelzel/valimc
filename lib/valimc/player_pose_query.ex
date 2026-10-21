defmodule Valimc.PlayerPoseQuery do
  @moduledoc "A resting player's pose and observations, sampled synchronously by its connection on its tick (VMC-077l)."
  import Bitwise

  alias Valimc.Physics.{
    CollisionContext,
    Kernel,
    PlayerPose,
    PoseFit
  }

  alias Valimc.World.View

  def signature(player) do
    {player.x, player.y, player.z, Map.get(player, :pose, :standing),
     (player.input.shared_flags &&& 2) != 0, player.abilities.flying,
     player.game_mode.current == :spectator, Valimc.PlayerMotion.distance(player),
     Valimc.PlayerKinetics.signature(player)}
  end

  @doc "The pose and observations of `player` where it stands, sampled now."
  def run(player) do
    position = {player.x, player.y, player.z}
    current = Map.get(player, :pose, :standing)
    shift = (player.input.shared_flags &&& 2) != 0

    intent = %PlayerPose{
      shift: shift,
      flying: player.abilities.flying,
      spectator: player.game_mode.current == :spectator
    }

    context = CollisionContext.player(player, player.y)

    # Standing encloses every pose currently produced by this preview's input.
    with {:ok, geometry} <- PlayerPose.geometry(:standing, position),
         {:ok, query} <- Valimc.PlayerKinetics.query_box(geometry.box, player),
         true <- Kernel.bounded?(query) or {:error, :pose_query_limit},
         frame = View.load(View.new(), query),
         {:ok, swimming} <- Valimc.PlayerSwimming.sample(player, current, position, frame),
         {:ok, result} <-
           PoseFit.select(current, %{intent | swimming: swimming}, position, context, %{
             blocks: frame,
             entities: [],
             border: Valimc.World.Clock.border_snapshot(),
             subject: player.entity_id
           }),
         {:ok, powder} <- Valimc.Living.Freezing.sample(frame, result.geometry.box),
         {:ok, air} <- Valimc.Living.Air.contact(frame, result.geometry),
         candidate =
           Map.put(player, :motion, %{
             Map.get(player, :motion, %Valimc.PlayerMotion{})
             | swimming: swimming
           }),
         {:ok, kinetics} <- Valimc.PlayerKinetics.tick(candidate, result.pose, frame),
         {:ok, rain} <- Valimc.PlayerRainQuery.sample(position, result.geometry, frame) do
      {:ok,
       result
       |> Map.put(:powder_snow, powder)
       |> Map.put(:submerged, air.submerged)
       |> Map.put(:eye_water, air.water)
       |> Map.put(:kinetics, Map.put(kinetics, :rain, rain))
       |> Map.put(:swimming, swimming)
       |> Map.put(:sources, View.owners(frame))}
    end
  end
end
