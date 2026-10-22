defmodule Valimc.Commands.Parser.ParticleInput do
  @moduledoc """
  The `particle` argument (VMC-053i): vanilla `ParticleArgument`, an id and
  optional SNBT options decoded as the particle type's codec, encoded for
  `level_particles` (type id, then the type's options). Option types ValiMC does
  not encode yet (`item`, `vibration`, `trail`, `shriek`, `sculk_charge`,
  geyser particles, `dust_color_transition`) are refused when given options.
  """
  alias Valimc.Data.Float32
  alias Valimc.Text.{Error, Reader, Snbt}
  alias Valimc.Text.Identifier
  alias Valimc.Protocol.Wire

  def parse(reader) do
    {id, reader} = Identifier.read(reader)
    row = Valimc.Commands.Facts.particle(id) || Error.fail_at!("particle.notFound", [id], reader)

    {options, reader} =
      if Reader.at?(reader, ?{), do: Snbt.parse_compound(reader), else: {{:compound, %{}}, reader}

    case options(id, options, row) do
      {:ok, bytes} -> {{id, IO.iodata_to_binary([Wire.varint(row["network_id"]), bytes])}, reader}
      {:error, message} -> Error.fail!("particle.invalidOptions", [message])
      :unsupported -> Error.refuse!("Options for the particle #{id} are not supported yet")
    end
  end

  @blocks ~w(minecraft:block minecraft:block_marker minecraft:falling_dust minecraft:dust_pillar minecraft:block_crumble)
  @colors ~w(minecraft:entity_effect minecraft:tinted_leaves minecraft:flash)

  defp options("minecraft:dust", {:compound, fields} = tag, _row) do
    with :ok <- missing(tag, ["scale", "color"]),
         {:ok, color} <- rgb(fields["color"]),
         {:ok, scale} <- scale(fields["scale"]) do
      {:ok, <<color::signed-32, scale::float-32>>}
    end
  end

  defp options(id, {:compound, fields} = tag, _row) when id in @blocks do
    with :ok <- missing(tag, ["block_state"]), do: block_state(fields["block_state"])
  end

  defp options(id, {:compound, fields} = tag, _row) when id in @colors do
    with :ok <- missing(tag, ["color"]) do
      case fields["color"] do
        {type, value} when type in [:byte, :short, :int] -> {:ok, <<value::signed-32>>}
        _ -> :unsupported
      end
    end
  end

  defp options("minecraft:dragon_breath", {:compound, fields}, _row) do
    case fields["power"] do
      nil -> {:ok, <<1.0::float-32>>}
      value -> with({:ok, power} <- float(value), do: {:ok, <<power::float-32>>})
    end
  end

  defp options(id, {:compound, fields}, _row)
       when id in ["minecraft:effect", "minecraft:instant_effect"] do
    with {:ok, color} <- if(fields["color"], do: rgb(fields["color"]), else: {:ok, -1}),
         {:ok, power} <- if(fields["power"], do: float(fields["power"]), else: {:ok, 1.0}) do
      {:ok, <<color::signed-32, power::float-32>>}
    end
  end

  defp options(_id, {:compound, fields}, %{"missing_options" => message}),
    do: if(fields == %{}, do: {:error, message}, else: :unsupported)

  defp options(_id, _tag, _row), do: {:ok, <<>>}

  # Required fields, reported last field first like a DFU record.
  defp missing({:compound, fields} = tag, keys) do
    case for key <- keys,
             not Map.has_key?(fields, key),
             do: "No key #{key} in MapLike[#{Snbt.to_string(tag)}]" do
      [] -> :ok
      messages -> {:error, Enum.join(messages, "; ")}
    end
  end

  # `ExtraCodecs.RGB_COLOR_CODEC`: a packed int, or [r, g, b] floats.
  defp rgb({type, value}) when type in [:byte, :short, :int], do: {:ok, value}

  defp rgb({:list, {type, [r, g, b]}}) when type in [:float, :double] do
    [r, g, b] = Enum.map([r, g, b], &channel(&1, type))
    <<color::signed-32>> = <<255, r, g, b>>
    {:ok, color}
  end

  defp rgb(_), do: :unsupported

  defp channel(<<v::float-32>>, :float), do: channel_value(v)
  defp channel(<<v::float-64>>, :double), do: channel_value(v)
  defp channel_value(v), do: v |> Kernel.*(255) |> floor() |> max(0) |> min(255)

  defp scale(value) do
    with {:ok, scale} <- float(value) do
      if scale >= 0.01 and scale <= 4.0,
        do: {:ok, scale},
        else: {:error, "Value must be within range [0.01;4.0]: #{scale}"}
    end
  end

  defp float({:float, <<v::float-32>>}), do: {:ok, v}
  defp float({:double, <<v::float-64>>}), do: {:ok, Float32.round_or_infinity(v)}
  defp float({type, v}) when type in [:byte, :short, :int, :long], do: {:ok, v * 1.0}
  defp float(_), do: {:error, "Not a number"}

  # A block name (its default state) as the state id on the wire; full state
  # compounds are not decoded yet.
  defp block_state({:string, name}) do
    case Identifier.parse(name) do
      {:ok, "minecraft:" <> block} ->
        if Valimc.Data.Blocks.id(block),
          do: {:ok, Wire.varint(Valimc.Data.Blocks.default_state(block))},
          else: :unsupported

      _ ->
        :unsupported
    end
  end

  defp block_state(_), do: :unsupported
end
