defmodule Valimc.PlayerPoseQuery do
  @moduledoc "Bounded pose geometry work; the player process alone commits selected poses."
  import Bitwise

  alias Valimc.Physics.{
    BlockCollisions,
    BorderSnapshot,
    CollisionContext,
    CollisionQuery,
    PlayerPose,
    PoseFit
  }

  def signature(player) do
    {player.x, player.y, player.z, Map.get(player, :pose, :standing),
     (player.input.shared_flags &&& 2) != 0, player.abilities.flying,
     player.game_mode.current == :spectator, Valimc.PlayerMotion.distance(player),
     Valimc.PlayerKinetics.signature(player)}
  end

  def start(player) do
    position = {player.x, player.y, player.z}
    current = Map.get(player, :pose, :standing)
    subject = player.entity_id
    shift = (player.input.shared_flags &&& 2) != 0

    intent = %PlayerPose{
      shift: shift,
      flying: player.abilities.flying,
      spectator: player.game_mode.current == :spectator
    }

    context =
      CollisionContext.entity(player.y, shift)
      |> CollisionContext.with_entity(Valimc.PlayerMotion.distance(player), false, false)

    # Standing encloses every pose currently produced by this preview's input.
    # Missing block-entity facts remain errors; they never become empty space.
    with {:ok, geometry} <- PlayerPose.geometry(:standing, position),
         {:ok, query} <- Valimc.PlayerKinetics.query_box(geometry.box, player) do
      CollisionQuery.start_frame(query, context, fn blocks ->
        with {:ok, frame} <- BlockCollisions.prepare(blocks) do
          with {:ok, swimming} <- Valimc.PlayerSwimming.sample(player, current, position, frame),
               {:ok, result} <-
                 PoseFit.select(current, %{intent | swimming: swimming}, position, context, %{
                   blocks: frame,
                   block_entities: %{},
                   entities: [],
                   border: %BorderSnapshot{},
                   subject: subject
                 }),
               {:ok, powder} <- Valimc.PlayerEnvironment.sample(frame, result.geometry.box),
               {:ok, air} <- Valimc.PlayerAir.contact(frame, result.geometry),
               candidate =
                 Map.put(player, :motion, %{
                   Map.get(player, :motion, %Valimc.PlayerMotion{})
                   | swimming: swimming
                 }),
               {:ok, kinetics} <- Valimc.PlayerKinetics.tick(candidate, result.pose, frame),
               do:
                 {:ok,
                  result
                  |> Map.put(:powder_snow, powder)
                  |> Map.put(:submerged, air.submerged)
                  |> Map.put(:eye_water, air.water)
                  |> Map.put(:kinetics, kinetics)
                  |> Map.put(:swimming, swimming)}
        end
      end)
    end
  end
end
