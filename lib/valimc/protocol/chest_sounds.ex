defmodule Valimc.Protocol.ChestSounds do
  @moduledoc "Pinned ordinary chest and barrel sound bodies and native float32 pitch; delivery belongs to viewer ownership."
  alias Valimc.Data.Float32
  alias Valimc.Protocol.{Packets, Wire}
  use Valimc.Data.Facts, "protocol/chest_sounds.json"
  @source @facts["blocks_source"]
  @open @facts["sounds"]["minecraft:block.chest.open"]
  @close @facts["sounds"]["minecraft:block.chest.close"]
  @barrel_open @facts["sounds"]["minecraft:block.barrel.open"]
  @barrel_close @facts["sounds"]["minecraft:block.barrel.close"]
  unless @source == 4 and @open == 349 and @close == 347 and @barrel_open == 141 and
           @barrel_close == 140,
         do: raise("Wrong ordinary chest sound facts")

  def pitch(draw) when is_number(draw) and draw >= 0 and draw < 1,
    do:
      {:ok,
       Float32.round(Float32.round(0.9) + Float32.round(Float32.round(draw) * Float32.round(0.1)))}

  def pitch(_), do: {:error, :invalid_chest_sound}

  def packet(open?, {x, y, z}, draw, seed)
      when is_boolean(open?) and is_number(x) and is_integer(y) and is_number(z) and
             abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and y in -64..319 and
             is_integer(seed) and seed >= -9_223_372_036_854_775_808 and
             seed <= 9_223_372_036_854_775_807 do
    with {:ok, pitch} <- pitch(draw) do
      {:ok,
       Packets.packet("sound", [
         Wire.varint(if(open?, do: @open, else: @close) + 1),
         Wire.varint(@source),
         <<trunc(8 * x + 4)::signed-32, 8 * y + 4::signed-32, trunc(8 * z + 4)::signed-32,
           0.5::float-32, pitch::float-32, seed::signed-64>>
       ])}
    end
  end

  def packet(_, _, _, _), do: {:error, :invalid_chest_sound}

  @doc """
  A barrel's open or close sound at `at`, the centre of its front face
  (`BarrelBlockEntity.playSound`: volume 0.5, the chest's pitch draw).
  """
  def barrel_packet(open?, {x, y, z}, draw, seed)
      when is_boolean(open?) and is_number(x) and is_number(y) and is_number(z) and
             abs(x) <= 29_999_985 and abs(z) <= 29_999_985 and y >= -64 and y <= 320 and
             is_integer(seed) and seed >= -9_223_372_036_854_775_808 and
             seed <= 9_223_372_036_854_775_807 do
    with {:ok, pitch} <- pitch(draw) do
      {:ok,
       Packets.packet("sound", [
         Wire.varint(if(open?, do: @barrel_open, else: @barrel_close) + 1),
         Wire.varint(@source),
         <<trunc(8 * x)::signed-32, trunc(8 * y)::signed-32, trunc(8 * z)::signed-32,
           0.5::float-32, pitch::float-32, seed::signed-64>>
       ])}
    end
  end

  def barrel_packet(_, _, _, _), do: {:error, :invalid_chest_sound}

  @doc "Native stock sound range16, measured from the block center to the player's feet."
  def audible?(%{x: px, y: py, z: pz}, {x, y, z}) do
    dx = x + 0.5 - px
    dy = y + 0.5 - py
    dz = z + 0.5 - pz
    dx * dx + dy * dy + dz * dz < 256.0
  end
end
