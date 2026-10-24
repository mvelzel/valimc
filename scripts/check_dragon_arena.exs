alias Valimc.World.Dragon.{Fight, Podium}
alias Valimc.Protocol.BossPackets

[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

defmodule DragonArenaCheck do
  def same(a, b, _label) when a == b, do: :ok
  def same(a, b, label), do: raise("#{label}: #{inspect(a)} != #{inspect(b)}")
  def list(tuple), do: tuple |> Tuple.to_list()
end

for row <- raw["podiums"] do
  initial = if row["clutter"], do: Valimc.Data.Blocks.default_state("stone"), else: 0

  {writes, drops} = Podium.plan({-7, 68, 12}, row["active"], fn _ -> initial end)
  writes = for {at, block} <- writes, do: DragonArenaCheck.list(at) ++ [block]
  drops = for {at, old} <- drops, do: DragonArenaCheck.list(at) ++ [old]

  DragonArenaCheck.same(writes, row["writes"], "podium writes #{inspect(row["active"])}")
  DragonArenaCheck.same(drops, row["drops"], "podium drop intent")
end

for row <- raw["seeds"] do
  seed = String.to_integer(row["seed"])
  DragonArenaCheck.same(Fight.new(seed).gateways, row["gateways"], "seed #{seed} gateway order")
  points = for n <- 0..19, do: DragonArenaCheck.list(Fight.gateway(n))
  DragonArenaCheck.same(points, row["gateway_positions"], "gateway positions")
  spikes = for s <- Fight.spikes(seed), do: Map.new(s, fn {k, v} -> {Atom.to_string(k), v} end)
  DragonArenaCheck.same(spikes, row["spikes"], "generation spike descriptions")
end

uuid = <<1234::64, 5678::64>>
title = Valimc.Text.translatable("entity.minecraft.ender_dragon")

for {key, expected} <- raw["packets"] do
  packet =
    case String.split(key, "_") do
      ["add", flags] ->
        BossPackets.add(uuid, title, 0.375, 0, 0, String.to_integer(flags))

      ["flags", flags] ->
        BossPackets.flags(uuid, String.to_integer(flags))

      ["remove"] ->
        BossPackets.remove(uuid)

      ["progress"] ->
        BossPackets.progress(uuid, 0.375)

      ["name"] ->
        BossPackets.name(uuid, Valimc.Text.literal("The returned dragon"))

      ["style", color, overlay] ->
        BossPackets.style(uuid, String.to_integer(color), String.to_integer(overlay))
    end

  {id, payload} = packet
  bytes = IO.iodata_to_binary([Valimc.Protocol.Wire.varint(id), payload])
  DragonArenaCheck.same(bytes, Base.decode16!(expected, case: :lower), key)
end

spikes =
  raw["seeds"]
  |> Enum.find(&(&1["seed"] == "20261024"))
  |> Map.fetch!("spikes")
  |> Enum.map(fn s ->
    %{x: s["x"], z: s["z"], height: s["height"], radius: s["radius"], guarded: s["guarded"]}
  end)

fight = %{Fight.new(20_261_024) | killed: true, stage: :start, crystals: [700, 701, 702, 703]}

final =
  raw["ritual"]
  |> Enum.with_index()
  |> Enum.reduce({fight, [nil, nil, nil, nil]}, fn {row, index}, {fight, beams} ->
    {next, effects} = Fight.ritual(fight, spikes, MapSet.new(700..703))
    label = "ritual tick #{index + 1}"

    DragonArenaCheck.same(
      if(next.stage, do: Atom.to_string(next.stage), else: "end"),
      row["stage"],
      label <> " stage"
    )

    DragonArenaCheck.same(next.time, row["time"], label <> " time")

    beams =
      Enum.reduce(effects, beams, fn
        {:beam, _, at}, _ -> List.duplicate(DragonArenaCheck.list(at), 4)
        {:ritual_explode, id}, beams -> List.replace_at(beams, id - 700, nil)
        _, beams -> beams
      end)

    DragonArenaCheck.same(beams, row["beams"], label <> " beams")
    events = for {:event, id, at} <- effects, do: [id | DragonArenaCheck.list(at)]
    DragonArenaCheck.same(events, row["events"], label <> " events")

    explosions =
      Enum.flat_map(effects, fn
        {:pillar, s} ->
          [
            %{
              "position" => [s.x + 0.5, s.height * 1.0, s.z + 0.5],
              "radius" => 5.0,
              "blocks" => "BLOCK"
            }
          ]

        {:ritual_explode, id} ->
          [%{"position" => [(id - 700) * 3.0, 69.0, 0.0], "radius" => 6.0, "blocks" => "NONE"}]

        _ ->
          []
      end)

    DragonArenaCheck.same(explosions, row["explosions"], label <> " explosions")

    added =
      for {:pillar, s} <- effects,
          do: %{
            "position" => [s.x + 0.5, s.height + 1.0, s.z + 0.5],
            "invulnerable" => true,
            "beam" => [0.0, 128.0, 0.0]
          }

    DragonArenaCheck.same(added, row["added"], label <> " crystals")
    DragonArenaCheck.same(:reset_spike_crystals in effects, row["reset"], label <> " reset")
    DragonArenaCheck.same(:spawn_dragon in effects, row["removed"], label <> " completion")
    {next, beams}
  end)

true = elem(final, 0).stage == nil

IO.puts(
  "PASS: native podium writes/drop intent, seven gateway seeds, #{map_size(raw["packets"])} boss packets and all #{length(raw["ritual"])} ritual ticks"
)
