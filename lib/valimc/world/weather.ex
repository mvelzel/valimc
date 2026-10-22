defmodule Valimc.World.Weather do
  @moduledoc "Pure Overworld weather timers, owned random stream and native float32 intensity ramps."
  alias Valimc.Data.Float32
  import Bitwise
  @mask 0xFFFFFFFFFFFF
  @multiplier 0x5DEECE66D
  defstruct clear_time: 0,
            rain_time: 0,
            thunder_time: 0,
            raining: false,
            thundering: false,
            rain_level: 0.0,
            thunder_level: 0.0,
            advance_weather: true,
            random_seed: 0

  def new do
    <<seed::64>> = :crypto.strong_rand_bytes(8)
    %__MODULE__{random_seed: seed(seed)}
  end

  def seed(value), do: bxor(value, @multiplier) &&& @mask

  def valid?(%__MODULE__{} = state) do
    Enum.all?(
      [state.clear_time, state.rain_time, state.thunder_time],
      &(is_integer(&1) and &1 in -2_147_483_648..2_147_483_647)
    ) and
      Enum.all?([state.raining, state.thundering, state.advance_weather], &is_boolean/1) and
      Enum.all?(
        [state.rain_level, state.thunder_level],
        &(is_float(&1) and &1 >= 0.0 and &1 <= 1.0)
      ) and
      is_integer(state.random_seed) and state.random_seed in 0..@mask
  end

  def valid?(_), do: false
  def wet?(state), do: state.rain_level > 0.2

  def prepare(state) do
    %{
      state
      | rain_level: if(state.raining, do: 1.0, else: 0.0),
        thunder_level: if(state.raining and state.thundering, do: 1.0, else: 0.0)
    }
  end

  def configure(state, kind, duration)
      when kind in [:clear, :rain, :thunder] and is_integer(duration) and
             duration in 0..2_147_483_647 do
    if kind == :clear do
      {:ok,
       %{
         state
         | clear_time: duration,
           rain_time: 0,
           thunder_time: 0,
           raining: false,
           thundering: false
       }}
    else
      {:ok,
       %{
         state
         | clear_time: 0,
           rain_time: duration,
           thunder_time: duration,
           raining: true,
           thundering: kind == :thunder
       }}
    end
  end

  def configure(_, _, _), do: {:error, :invalid_weather_change}

  def tick(state, can_have_weather \\ true)
  def tick(state, false), do: state

  def tick(state, true) do
    next = cycle(state)

    %{
      next
      | rain_level: intensity(state.rain_level, next.raining),
        thunder_level: intensity(state.thunder_level, next.thundering)
    }
  end

  defp cycle(%{advance_weather: false} = state), do: state

  defp cycle(%{clear_time: clear} = state) when clear > 0 do
    %{
      state
      | clear_time: clear - 1,
        thunder_time: if(state.thundering, do: 0, else: 1),
        rain_time: if(state.raining, do: 0, else: 1),
        raining: false,
        thundering: false
    }
  end

  defp cycle(state) do
    {thunder, thundering, seed} =
      timer(
        state.thunder_time,
        state.thundering,
        if(state.thundering, do: {3600, 15600}, else: {12000, 180_000}),
        state.random_seed
      )

    {rain, raining, seed} =
      timer(
        state.rain_time,
        state.raining,
        if(state.raining, do: {12000, 24000}, else: {12000, 180_000}),
        seed
      )

    %{
      state
      | thunder_time: thunder,
        thundering: thundering,
        rain_time: rain,
        raining: raining,
        random_seed: seed
    }
  end

  defp timer(time, flag, _, seed) when time > 0,
    do: {time - 1, if(time == 1, do: not flag, else: flag), seed}

  defp timer(_, flag, {low, high}, seed) do
    {value, seed} = next_int(seed, high - low + 1, 16)
    {low + value, flag, seed}
  end

  defp next_int(_, _, 0), do: raise("weather random rejection budget exhausted")

  defp next_int(seed, bound, budget) do
    next = seed * @multiplier + 11 &&& @mask
    bits = next >>> 17
    value = rem(bits, bound)

    if bits - value + bound - 1 < 2_147_483_648,
      do: {value, next},
      else: next_int(next, bound, budget - 1)
  end

  defp intensity(value, flag) do
    step = Float32.round(0.01)
    delta = if flag, do: step, else: -step
    value |> Kernel.+(delta) |> Float32.round() |> max(0.0) |> min(1.0)
  end
end
