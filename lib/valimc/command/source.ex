defmodule Valimc.Command.Source do
  @moduledoc """
  A command source (VMC-053): vanilla's `CommandSourceStack` for a player — its
  permission level, position, rotation and display name, plus the owning
  connection state that executes the command.
  """
  alias Valimc.Command.{Text, Coordinates, Selector, Error}

  defstruct [:level, :state, :player, :name, :position, :rotation]

  def player(state) do
    player = Map.put(state.player, :pid, self())

    %__MODULE__{
      level: Valimc.Permissions.level(player),
      state: state,
      player: player,
      name: player.name,
      position: {player.x, player.y, player.z},
      rotation: {player.yaw, player.pitch}
    }
  end

  @doc """
  The server console (VMC-010f), vanilla's `MinecraftServer.createCommandSourceStack`:
  permission level 4, named Server, at the world spawn, with no player.
  """
  def console do
    pose = Valimc.World.Spawn.pose()
    {x, y, z} = {pose.x, pose.y, pose.z}

    %__MODULE__{
      level: 4,
      name: "Server",
      position: {floor(x) * 1.0, floor(y) * 1.0, floor(z) * 1.0},
      rotation: {0.0, 0.0}
    }
  end

  def console?(%__MODULE__{player: nil, state: nil}), do: true
  def console?(_), do: false

  @doc "The executing player, or `permissions.requires.player` (`getPlayerOrException`)."
  def player!(%__MODULE__{player: nil}), do: Error.fail!("permissions.requires.player")
  def player!(%__MODULE__{player: player}), do: player

  @doc "A source for parsing only (the parse oracle), at a permission level."
  def parse_only(level),
    do: %__MODULE__{level: level, name: "", position: {0.0, 0.0, 0.0}, rotation: {0.0, 0.0}}

  def display_name(%__MODULE__{player: nil, name: name}), do: Text.literal(name)
  def display_name(%__MODULE__{player: player}), do: Text.player_name(player.name, player.uuid)
  def display_name(%{name: name, uuid: uuid}), do: Text.player_name(name, uuid)

  @doc "Online players a selector picks, the source itself included (`findPlayers`)."
  def players(%__MODULE__{} = source, selector) do
    candidates =
      case source.player do
        nil -> Valimc.Players.all()
        player -> [player | Enum.reject(Valimc.Players.all(), &(&1.pid == self()))]
      end

    Selector.find(selector, candidates, source.player, source.position)
  end

  @doc "`EntityArgument.getPlayers`: at least one player or `argument.entity.notfound.player`."
  def required_players(source, selector) do
    case players(source, selector) do
      [] -> Error.fail!("argument.entity.notfound.player")
      players -> players
    end
  end

  @doc "`getEntities`: at least one entity (players are ValiMC's selectable entities)."
  def required_entities(source, selector) do
    case players(source, selector) do
      [] -> Error.fail!("argument.entity.notfound.entity")
      entities -> entities
    end
  end

  @doc "`getPlayer`/`getEntity`: exactly one, with vanilla's not-found errors."
  def single_player(source, selector) do
    case players(source, selector) do
      [player] -> player
      [] -> Error.fail!("argument.entity.notfound.player")
      _ -> Error.fail!("argument.player.toomany")
    end
  end

  def single_entity(source, selector) do
    case players(source, selector) do
      [entity] -> entity
      [] -> Error.fail!("argument.entity.notfound.entity")
      _ -> Error.fail!("argument.entity.toomany")
    end
  end

  def position(%__MODULE__{} = source, coordinates),
    do: Coordinates.position(coordinates, source.position, source.rotation)

  def block_pos(%__MODULE__{} = source, coordinates),
    do: Coordinates.block(coordinates, source.position, source.rotation)

  def self?(%__MODULE__{player: nil}, _target), do: false
  def self?(%__MODULE__{player: player}, target), do: target.pid == player.pid
end
