defmodule Valimc.World.ClockRecord do
  @moduledoc "Small checksummed world clock snapshots; private preview format, not vanilla saved-data NBT."
  alias Valimc.Protocol.Data
  alias Valimc.World.ClockState
  @names Data.registries()["minecraft:world_clock"]
  @max_bytes 256
  def names, do: @names
  def max_bytes, do: @max_bytes
  def new, do: %{game_time: 0, advance_time: true, clocks: Map.new(@names, &{&1, %ClockState{}})}

  def valid?(%{game_time: time, advance_time: advance, clocks: clocks}) do
    is_integer(time) and time in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 and
      is_boolean(advance) and is_map(clocks) and Enum.sort(Map.keys(clocks)) == Enum.sort(@names) and
      Enum.all?(clocks, fn {_, clock} -> ClockState.valid?(clock) end)
  end

  def valid?(_), do: false

  def tick(data) do
    clocks =
      if data.advance_time,
        do: Map.new(data.clocks, fn {name, clock} -> {name, ClockState.tick(clock)} end),
        else: data.clocks

    %{data | game_time: ClockState.long(data.game_time + 1), clocks: clocks}
  end

  def encode(data) do
    if valid?(data) do
      entries =
        Enum.map(@names, fn name ->
          clock = data.clocks[name]

          <<clock.total_ticks::signed-64, clock.partial_tick::float-32, clock.rate::float-32,
            if(clock.paused, do: 1, else: 0)>>
        end)

      body =
        IO.iodata_to_binary([
          <<"VMCLOCK", 1, 5023::32, data.game_time::signed-64,
            if(data.advance_time, do: 1, else: 0), length(@names)>>,
          entries
        ])

      {:ok, body <> :crypto.hash(:sha256, body)}
    else
      {:error, :invalid_clock_state}
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    body_size = byte_size(bytes) - 32
    <<body::binary-size(^body_size), checksum::binary-size(32)>> = bytes
    true = checksum == :crypto.hash(:sha256, body)
    <<"VMCLOCK", 1, 5023::32, time::signed-64, advance, count, entries::binary>> = body
    true = advance in [0, 1] and count == length(@names)

    {clocks, <<>>} =
      Enum.reduce(@names, {%{}, entries}, fn name, {acc, rest} ->
        <<total::signed-64, partial::float-32, rate::float-32, paused, tail::binary>> = rest
        true = paused in [0, 1]

        {Map.put(acc, name, %ClockState{
           total_ticks: total,
           partial_tick: partial,
           rate: rate,
           paused: paused == 1
         }), tail}
      end)

    data = %{game_time: time, advance_time: advance == 1, clocks: clocks}
    true = valid?(data)
    {:ok, data}
  rescue
    _ -> {:error, :invalid_clock_file}
  end

  def decode(_), do: {:error, :invalid_clock_file}
end
