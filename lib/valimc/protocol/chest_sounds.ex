defmodule Valimc.Protocol.ChestSounds do
  @moduledoc "Pinned ordinary chest sound bodies and native float32 pitch; delivery belongs to viewer ownership."
  alias Valimc.Protocol.{Packets, Wire}
  @path Path.expand("../../../priv/protocol/chest_sounds.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @source @facts["blocks_source"]
  @open @facts["sounds"]["minecraft:block.chest.open"]
  @close @facts["sounds"]["minecraft:block.chest.close"]
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           @source == 4 and @open == 349 and @close == 347,
         do: raise("Wrong ordinary chest sound facts")

  def pitch(draw) when is_number(draw) and draw >= 0 and draw < 1,
    do: {:ok, f32(f32(0.9) + f32(f32(draw) * f32(0.1)))}

  def pitch(_), do: {:error, :invalid_chest_sound}

  def packet(open?, {x, y, z}, draw, seed)
      when is_boolean(open?) and is_integer(x) and is_integer(y) and is_integer(z) and
             abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and y in -64..319 and
             is_integer(seed) and seed >= -9_223_372_036_854_775_808 and
             seed <= 9_223_372_036_854_775_807 do
    with {:ok, pitch} <- pitch(draw) do
      {:ok,
       Packets.packet("sound", [
         Wire.varint(if(open?, do: @open, else: @close) + 1),
         Wire.varint(@source),
         <<8 * x + 4::signed-32, 8 * y + 4::signed-32, 8 * z + 4::signed-32, 0.5::float-32,
           pitch::float-32, seed::signed-64>>
       ])}
    end
  end

  def packet(_, _, _, _), do: {:error, :invalid_chest_sound}

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
