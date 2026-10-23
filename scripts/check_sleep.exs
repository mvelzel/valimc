# VMC-040a: stand-up positions, respawn points, sleep checks, the sleep
# status and the sleep packets against vanilla's (`SleepOracle fixtures`).
alias Valimc.World.StandUp
Valimc.Data.BlockFacts.install!()

[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()
true = raw["version"] == "26.3"

decode = fn bits ->
  <<v::float-64>> = Base.decode16!(bits, case: :lower)
  v
end

vector = fn
  nil -> nil
  [x, y, z] -> {decode.(x), decode.(y), decode.(z)}
end

float = fn bits ->
  <<v::float-32>> = <<bits::32>>
  v
end

scenes =
  raw["scenes"]
  |> Enum.map(fn %{"cells" => cells} ->
    states = Map.new(cells, fn [x, y, z, s] -> {{x, y, z}, s} end)
    # Vanilla's probe reads air around the scene; the kernel reads a halo.
    {xs, ys, zs} =
      {Enum.map(cells, &Enum.at(&1, 0)), Enum.map(cells, &Enum.at(&1, 1)),
       Enum.map(cells, &Enum.at(&1, 2))}

    air =
      for x <- (Enum.min(xs) - 3)..(Enum.max(xs) + 3),
          y <- (Enum.min(ys) - 3)..(Enum.max(ys) + 3),
          z <- (Enum.min(zs) - 3)..(Enum.max(zs) + 3),
          into: %{},
          do: {{x, y, z}, 0}

    Valimc.World.View.of(Map.merge(air, states))
  end)
  |> List.to_tuple()

facing = &String.to_existing_atom/1

for row <- raw["stand_ups"] do
  view = elem(scenes, row["scene"])
  position = List.to_tuple(row["position"])

  result =
    case row["kind"] do
      "bed" -> StandUp.bed(view, position, facing.(row["facing"]), float.(row["yaw"]))
      "anchor" -> StandUp.anchor(view, position)
    end

  unless result == vector.(row["result"]),
    do: raise("stand-up #{inspect(row)}: #{inspect(result)}")
end

for row <- raw["respawns"] do
  view = elem(scenes, row["scene"])
  position = List.to_tuple(row["position"])
  "minecraft:" <> dimension = row["dimension"]

  view =
    if row["missing"],
      do: %{view | supplied: Map.put(view.supplied, position, row["state"])},
      else: view

  point = %{position: position, yaw: float.(row["yaw"])}
  result = StandUp.respawn(view, String.to_atom(dimension), point)

  expected =
    if row["result"],
      do:
        {vector.(row["result"]), float.(row["result_yaw"]), float.(row["result_pitch"]),
         if(row["after"] != row["state"], do: row["after"])}

  unless result == expected,
    do: raise("respawn #{inspect(Map.drop(row, ["scene"]))}: #{inspect(result)}")
end

IO.puts(
  "PASS: #{length(raw["stand_ups"])} stand-up searches and #{length(raw["respawns"])} " <>
    "respawn points equal vanilla's"
)

# `bedInRange` and `bedBlocked`.
for row <- raw["ranges"] do
  result =
    Valimc.Player.Sleep.in_range?(
      vector.(row["player"]),
      List.to_tuple(row["position"]),
      facing.(row["facing"])
    )

  unless result == row["in_range"], do: raise("bed range #{inspect(row)}: #{result}")
end

for row <- raw["blocked"] do
  view = elem(scenes, row["scene"])

  result =
    Valimc.Player.Sleep.blocked?(view, List.to_tuple(row["position"]), facing.(row["facing"]))

  unless result == row["blocked"], do: raise("bed blocked #{inspect(row)}: #{result}")
end

# `SleepStatus`: who must sleep for the night to skip.
alias Valimc.World.SleepStatus

for row <- raw["sleep_status"] do
  needed = SleepStatus.needed(row["active"], row["percentage"])
  enough = SleepStatus.enough?(row["sleeping"], row["active"], row["percentage"])

  unless needed == row["needed"] and enough == row["enough"],
    do: raise("sleep status #{inspect(row)}: #{needed} #{enough}")
end

IO.puts(
  "PASS: #{length(raw["ranges"])} bed ranges, #{length(raw["blocked"])} obstructions and " <>
    "#{length(raw["sleep_status"])} sleep counts equal vanilla's"
)

# The packets: bytes where NBT is not in them, decoded components where it is.
packets = raw["packets"]

wire = fn {id, payload} ->
  Base.encode16(IO.iodata_to_binary([Valimc.Protocol.Wire.varint(id), payload]), case: :lower)
end

player = %{entity_id: 4242, pose: :sleeping, sleeping: %{bed: {-123, 70, 4567}, ticks: 0}}
alias Valimc.Player.Packets, as: PlayerPackets

for {name, packet} <- [
      wake_up: PlayerPackets.wake_up(4242),
      sleeping: PlayerPackets.player_sleeping(player),
      awake: PlayerPackets.player_sleeping(%{player | pose: :standing, sleeping: nil}),
      no_respawn_block: PlayerPackets.no_respawn_block()
    ] do
  unless wire.(packet) == packets[Atom.to_string(name)],
    do: raise("#{name} packet differs: #{wire.(packet)}")
end

component = fn hex ->
  <<_id, rest::binary>> = Base.decode16!(hex, case: :lower)
  size = byte_size(rest) - 1
  <<nbt::binary-size(^size), overlay>> = rest
  {:ok, tag} = Valimc.Data.NBT.decode(nbt)
  {tag, overlay}
end

text = Valimc.Text

for {name, packet} <- [
      players_sleeping: SleepStatus.packet(text.translatable("sleep.players_sleeping", [1, 2])),
      skipping_night: SleepStatus.packet(text.translatable("sleep.skipping_night")),
      spawn_set: Valimc.Protocol.Packets.chat(text.translatable("block.minecraft.set_spawn"))
    ] do
  unless component.(wire.(packet)) == component.(packets[Atom.to_string(name)]),
    do: raise("#{name} packet differs: #{wire.(packet)}")
end

# The bad respawn point's death message, its scaling and exhaustion.
to_tag = fn
  _to_tag, value when is_binary(value) ->
    {:string, value}

  to_tag, value when is_list(value) ->
    Valimc.Data.NBT.list(Enum.map(value, &to_tag.(to_tag, &1)))

  to_tag, value when is_map(value) ->
    {:compound, Map.new(value, fn {k, v} -> {k, to_tag.(to_tag, v)} end)}
end

%{tag: message} = Valimc.Living.DamageSource.death_message("ValiMCTest", :bad_respawn_point)

unless message == to_tag.(to_tag, packets["bad_respawn_point"]) and
         Valimc.Living.DamageSource.exhaustion(:bad_respawn_point) ==
           packets["bad_respawn_point_exhaustion"],
       do: raise("bad respawn point message differs: #{inspect(message)}")

IO.puts("PASS: the sleep packets and the bad respawn point's death message equal vanilla's")
