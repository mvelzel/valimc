defmodule Valimc.Physics.Mining do
  @moduledoc "Pinned block mining arithmetic; player/tool permissions and destruction belong to their owners."
  @path Path.expand("../../../priv/physics/mining_blocks.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @count @facts["state_count"]
  @float_max 3.4028234663852886e38
  @int_max 2_147_483_647
  @int_min -2_147_483_648
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           @count == Valimc.Protocol.Data.block_state_count(),
         do: raise("Wrong mining catalog version")

  @properties Enum.map(@facts["properties"], fn p ->
                hardness = p["hardness"]

                unless map_size(p) == 2 and is_number(hardness) and hardness >= -1 and
                         hardness <= @float_max and
                         is_boolean(p["requires_correct_tool"]),
                       do: raise("Invalid mining property")

                <<rounded::float-32>> = <<hardness::float-32>>
                unless rounded == hardness, do: raise("Noncanonical mining hardness")
                {hardness, p["requires_correct_tool"]}
              end)
              |> List.to_tuple()
  @states Base.decode16!(@facts["states"], case: :lower)
  unless byte_size(@states) == @count and tuple_size(@properties) in 1..256 and
           Enum.all?(:binary.bin_to_list(@states), &(&1 < tuple_size(@properties))),
         do: raise("Incomplete mining catalog")

  def hardness(id) when is_integer(id) and id >= 0 and id < @count, do: elem(property(id), 0)

  def requires_tool?(id) when is_integer(id) and id >= 0 and id < @count,
    do: elem(property(id), 1)

  @doc "Actual native rate with supplied destroy speed/harvest permission; nonfinite results are explicit."
  def rate(id, speed, correct)
      when is_integer(id) and id >= 0 and id < @count and
             is_number(speed) and speed >= 0 and speed <= @float_max and is_boolean(correct) do
    speed = f32(speed)

    case hardness(id) do
      -1.0 -> {:ok, 0.0}
      zero when zero == 0 -> {:ok, if(speed == 0, do: :nan, else: :infinity)}
      hardness -> {:ok, divide(f32(speed / hardness), if(correct, do: 30, else: 100))}
    end
  end

  def rate(_, _, _), do: {:error, :invalid_mining_input}

  @doc "Native elapsed+1 float progress and crack cast; callers decide completion and animation emission."
  def advance(rate, elapsed)
      when elapsed in 0..@int_max and
             (rate in [:nan, :infinity] or (is_number(rate) and rate >= 0 and rate <= @float_max)) do
    ticks = if elapsed == @int_max, do: @int_min, else: elapsed + 1
    progress = multiply(rate, f32(ticks))

    {:ok,
     %{
       progress: progress,
       crack: progress |> multiply(10.0) |> cast_int(),
       complete: at_least?(progress, 1.0),
       stoppable: at_least?(progress, f32(0.7))
     }}
  end

  def advance(_, _), do: {:error, :invalid_mining_input}

  defp property(id), do: elem(@properties, :binary.at(@states, id))
  defp divide(:infinity, _), do: :infinity
  defp divide(value, divisor), do: f32(value / divisor)
  defp multiply(:nan, _), do: :nan
  defp multiply(:infinity, number), do: if(number < 0, do: :negative_infinity, else: :infinity)

  defp multiply(:negative_infinity, number),
    do: if(number < 0, do: :infinity, else: :negative_infinity)

  defp multiply(value, number), do: f32(value * number)
  defp at_least?(:infinity, _), do: true
  defp at_least?(value, _) when value in [:negative_infinity, :nan], do: false
  defp at_least?(value, limit), do: value >= limit
  defp cast_int(:nan), do: 0
  defp cast_int(:infinity), do: @int_max
  defp cast_int(:negative_infinity), do: @int_min
  defp cast_int(value), do: value |> min(@int_max) |> max(@int_min) |> trunc()

  defp f32(value) do
    case <<value::float-32>> do
      <<0::1, 255::8, 0::23>> -> :infinity
      <<1::1, 255::8, 0::23>> -> :negative_infinity
      <<number::float-32>> -> number
    end
  end
end
