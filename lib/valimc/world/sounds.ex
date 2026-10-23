defmodule Valimc.World.Sounds do
  @moduledoc """
  Sounds at a position for the players near it (VMC-050a), as vanilla's
  `Level.playSound` with no excluded player sends them: the sound by its
  name (a direct holder), its source category, volume 1 and pitch 1, to
  the observers of the position's section within 16 blocks.
  """
  import Bitwise
  alias Valimc.Data.Grid
  alias Valimc.Protocol.{Packets, Wire}

  @sources ~w(master music record weather block hostile neutral player ambient voice ui)a

  @doc "Play sound `id` (`\"minecraft:...\"`) of `source` at the centre of cell `{x, y, z}`."
  def play({x, y, z}, id, source) do
    at = {x + 0.5, y + 0.5, z + 0.5}
    packet = packet(id, source, at, :rand.uniform(1 <<< 62))
    key = Grid.section(Valimc.World.Dimension.current(), Grid.chunk_key(x, z))
    Valimc.World.publish(key, {:sound, at, 16.0, packet})
  end

  @doc "The sound packet of `id` at `{x, y, z}` (volume and pitch 1)."
  def packet(id, source, {x, y, z}, seed) do
    Packets.packet("sound", [
      Wire.varint(0),
      Wire.string(id),
      <<0>>,
      Wire.varint(Enum.find_index(@sources, &(&1 == source))),
      <<trunc(x * 8)::signed-32, trunc(y * 8)::signed-32, trunc(z * 8)::signed-32>>,
      <<1.0::float-32, 1.0::float-32, seed::signed-64>>
    ])
  end
end
