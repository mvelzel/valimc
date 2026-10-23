defmodule Valimc.Player.RespawnPoint do
  @moduledoc """
  A player's respawn point (VMC-040a, vanilla's `ServerPlayer.RespawnConfig`):
  the bed it last lay down in or the respawn anchor it set, as
  `%{dimension, position, yaw, pitch, forced}`, saved with the player. A new
  point tells the player "Respawn point set" unless it is the same block.

  Respawning (`findRespawnPositionAndUseSpawnBlock`) reads the point's block
  in its dimension, loading its chunks as the world spawn search does: a bed
  whose rule sets spawns there, or a charged anchor where anchors work,
  stands the player up beside it (`Valimc.World.StandUp`) facing it; an
  anchor spends a charge, a fenced write at its owner, and the player hears
  it deplete. A missing, spent or blocked point is forgotten: the player
  respawns at the world spawn and is told it had no respawn block. Forced
  points (`/spawnpoint`) arrive with the command (VMC-053n).
  """
  alias Valimc.Data.Grid
  alias Valimc.Player.{Life, Sleep}
  alias Valimc.Protocol.Packets
  alias Valimc.World.{Clock, Dimension, PlayerSpawn, Spawning, StandUp, View}

  import Bitwise, only: [<<<: 2]
  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @dimensions [:overworld, :the_nether, :the_end]
  @deadline_ms 10_000

  @doc "Whether `point` is a respawn point a player file may hold."
  def valid?(nil), do: true

  def valid?(%{dimension: dimension, position: position, yaw: yaw, pitch: pitch, forced: forced}),
    do:
      dimension in @dimensions and Life.valid_location?(position) and position != nil and
        is_float(yaw) and is_float(pitch) and is_boolean(forced)

  def valid?(_), do: false

  @doc "Set the player's respawn point; with `message`, a new block says so."
  def set(state, point, message) do
    current = Map.get(state.player, :respawn)

    if message and point != nil and not same?(point, current),
      do:
        send_packets(state, [Packets.chat(Valimc.Text.translatable("block.minecraft.set_spawn"))])

    %{state | player: Map.put(state.player, :respawn, point)}
  end

  @doc "Whether two points name the same block of the same dimension."
  def same?(%{dimension: d, position: p}, %{dimension: d, position: p}), do: true
  def same?(_, _), do: false

  @doc """
  Where the player respawns: `{state, spawn}` with `spawn` as
  `Valimc.World.PlayerSpawn.find/1` gives it. A point that fails is
  forgotten and the client hears so before it respawns; an anchor's
  depletion sound plays after (`after_respawn/1`). Without `consume` (after
  the credits, which keep all data) an anchor keeps its charge.
  """
  def respawn(state, consume \\ true) do
    case Map.get(state.player, :respawn) do
      nil ->
        {state, PlayerSpawn.find()}

      point ->
        case resolve(point, consume, 2) do
          {:ok, spawn, anchor} ->
            {%{state | player: Map.put(state.player, :depleted, anchor)}, spawn}

          :missing ->
            send_packets(state, [Valimc.Player.Packets.no_respawn_block()])
            {%{state | player: Map.put(state.player, :respawn, nil)}, PlayerSpawn.find()}
        end
    end
  end

  @doc "After the respawn's packets: the spent anchor depletes (`RESPAWN_ANCHOR_DEPLETE`)."
  def after_respawn(%{player: %{depleted: {x, y, z}}} = state) do
    sound =
      Valimc.World.Sounds.packet(
        "minecraft:block.respawn_anchor.deplete",
        :block,
        {x * 1.0, y * 1.0, z * 1.0},
        :rand.uniform(1 <<< 62)
      )

    send_packets(state, [sound])
    %{state | player: Map.put(state.player, :depleted, nil)}
  end

  def after_respawn(state), do: state

  # The point's block decides; an anchor's charge is spent where it still
  # holds what was read (read again once if another change came first).
  defp resolve(%{dimension: dimension, position: {x, _, z} = position} = point, consume, tries) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms

    # The stand-up search reaches two cells and a player's box around it.
    {cx0, cz0} = Grid.chunk_key(x - 3, z - 3)
    {cx1, cz1} = Grid.chunk_key(x + 3, z + 3)
    chunks = for cx <- cx0..cx1, cz <- cz0..cz1, do: {cx, cz}

    with {:ok, view} <- View.await(View.new(dimension), chunks, :spawn_search, deadline),
         [before] when is_integer(before) <- View.blocks(view, [position]),
         border = Clock.border(Dimension.name(dimension)),
         {at, yaw, pitch, spent} <-
           StandUp.respawn(view, dimension, point, Spawning.dark?(dimension), border) do
      {sx, sy, sz} = at

      spawn = fn ->
        {:ok, %{dimension: dimension, x: sx, y: sy, z: sz, yaw: yaw, pitch: pitch},
         if(spent, do: position)}
      end

      cond do
        spent == nil or not consume -> put_elem(spawn.(), 2, nil)
        Sleep.write(dimension, %{position => spent}, %{position => before}) == :ok -> spawn.()
        tries > 1 -> resolve(point, consume, tries - 1)
        true -> :missing
      end
    else
      _ -> :missing
    end
  end
end
