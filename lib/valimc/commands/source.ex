defmodule Valimc.Commands.Source do
  @moduledoc """
  A command source (VMC-053, VMC-077o), vanilla's `CommandSourceStack`, as a
  plain value: permission level, the entity it runs as (a player's projection
  with its connection's `pid`, or nil), dimension, position, rotation and
  anchor, display name, the sink its feedback goes to and whether it is
  silent. A command runs in its own process (VMC-077a) and reads everything
  it needs from its source: no connection state, no `self()` identity and no
  process-dictionary dimension.

  Sinks: `{:player, pid}` (the player's connection, in order), `:log` (the
  console's English lines) and `{:collect, pid, ref}` (RCON, whose client
  collects `{ref, text}` messages after the command).
  """
  alias Valimc.Data.Grid
  alias Valimc.Commands.Parser.Coordinates
  alias Valimc.Text.Error
  alias Valimc.Text

  defstruct [
    :level,
    :player,
    :name,
    :position,
    :rotation,
    :dimension,
    :sink,
    anchor: :feet,
    silent: false,
    kind: :player
  ]

  @doc "The source of a command its player runs (built in its session; feedback goes to its connection)."
  def player(state) do
    player = Map.put(state.player, :pid, state.connection)

    %__MODULE__{
      level: Valimc.Admin.Permissions.level(player),
      player: player,
      name: player.name,
      position: {player.x, player.y, player.z},
      rotation: {player.yaw, player.pitch},
      dimension: Map.get(player, :dimension, :overworld),
      sink: {:player, state.connection}
    }
  end

  @doc """
  The server console (VMC-010f), vanilla's `MinecraftServer.createCommandSourceStack`:
  permission level 4, named Server, at the world spawn in its dimension
  (`findRespawnDimension`), with no player; its feedback is logged.
  """
  def console, do: server_source("Server", :console, :log)

  @doc """
  RCON (VMC-010g), vanilla's `RconConsoleSource`: as the console, named Rcon;
  its feedback is collected by the calling process (`collect/1`).
  """
  def rcon, do: server_source("Rcon", :rcon, {:collect, self(), make_ref()})

  defp server_source(name, kind, sink) do
    pose = Valimc.World.Spawn.pose()
    {x, y, z} = {pose.x, pose.y, pose.z}

    %__MODULE__{
      level: 4,
      name: name,
      kind: kind,
      sink: sink,
      position: {floor(x) * 1.0, floor(y) * 1.0, floor(z) * 1.0},
      rotation: {0.0, 0.0},
      dimension: Valimc.World.Spawn.dimension()
    }
  end

  @doc "The texts a collecting source received, in order (RCON's reply)."
  def collect(%__MODULE__{sink: {:collect, _pid, ref}}), do: collect(ref, [])

  defp collect(ref, texts) do
    receive do
      {^ref, text} -> collect(ref, [texts, text])
    after
      0 -> IO.iodata_to_binary(texts)
    end
  end

  def console?(%__MODULE__{kind: kind}), do: kind == :console

  @doc "The executing player, or `permissions.requires.player` (`getPlayerOrException`)."
  def player!(%__MODULE__{player: nil}), do: Error.fail!("permissions.requires.player")
  def player!(%__MODULE__{player: player}), do: player

  @doc "A source for parsing only (the parse oracle), at a permission level."
  def parse_only(level),
    do: %__MODULE__{
      level: level,
      name: "",
      position: {0.0, 0.0, 0.0},
      rotation: {0.0, 0.0},
      dimension: :overworld,
      sink: :log
    }

  def display_name(%__MODULE__{player: nil, name: name}), do: Text.literal(name)
  def display_name(%__MODULE__{player: player}), do: Text.player_name(player.name, player.uuid)
  # A body (VMC-043a) by its custom name or type, an item (VMC-043a1) by its stack.
  def display_name(%{kind: :body, display: display}), do: display

  def display_name(%{name: name, uuid: uuid}), do: Text.player_name(name, uuid)

  def position(%__MODULE__{} = source, coordinates),
    do: Coordinates.position(coordinates, source.position, source.rotation)

  def block_pos(%__MODULE__{} = source, coordinates),
    do: Coordinates.block(coordinates, source.position, source.rotation)

  @doc """
  A block position inside the world (`Level.isInWorldBounds`: the build height,
  and within 30,000,000 blocks horizontally), else `argument.pos.outofworld`.
  """
  def block_in_world!(%__MODULE__{} = source, coordinates) do
    {x, y, z} = block_pos(source, coordinates)

    unless Valimc.World.Chunk.valid_y?(y) and x >= -30_000_000 and x < 30_000_000 and
             z >= -30_000_000 and z < 30_000_000,
           do: Error.fail!("argument.pos.outofworld")

    {x, y, z}
  end

  @doc """
  The running region owner of `key` in the source's dimension; a region that
  is not loaded is not started (`argument.pos.unloaded` for the caller).
  """
  def owner(%__MODULE__{dimension: dimension}, key),
    do: Valimc.World.existing_owner(Grid.section(dimension, key, :section))

  def self?(%__MODULE__{player: nil}, _target), do: false
  def self?(%__MODULE__{player: player}, target), do: target.pid == player.pid
end
