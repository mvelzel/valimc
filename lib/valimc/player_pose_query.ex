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
     player.game_mode.current == :spectator}
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
      |> CollisionContext.with_entity(0.0, false, false)

    # Standing encloses every pose currently produced by this preview's input.
    # Missing block-entity facts remain errors; they never become empty space.
    with {:ok, geometry} <- PlayerPose.geometry(:standing, position) do
      CollisionQuery.start_frame(geometry.fit_box, context, fn blocks ->
        with {:ok, frame} <- BlockCollisions.prepare(blocks) do
          PoseFit.select(current, intent, position, context, %{
            blocks: frame,
            block_entities: %{},
            entities: [],
            border: %BorderSnapshot{},
            subject: subject
          })
        end
      end)
    end
  end
end
