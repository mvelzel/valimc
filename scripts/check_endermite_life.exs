alias Valimc.AI.World
alias Valimc.Entity.{Body, MobTicks, Store}
states = for x <- -5..5, y <- 59..70, z <- -5..5, into: %{}, do: {{x, y, z}, 0}

# `--native` (VMC-081d): the mob takes its turns in a native section
# (`MobTicks.native_steps/7`) over the same air.
{native, argv} = Enum.split_with(System.argv(), &(&1 == "--native"))
native? = native != []
if native?, do: Valimc.Entity.NativeMobs.install!()

packed =
  for {{x, y, z}, s} <- states,
      into: <<>>,
      do: <<x::signed-32, y::signed-32, z::signed-32, s::16>>

native_level = fn drops ->
  %{
    time: 0,
    day: 0,
    difficulty: :normal,
    darken: 0,
    bright: false,
    monsters_burn: false,
    halloween: false,
    mob_griefing: true,
    mob_drops: drops,
    entity_drops: true,
    universal_anger: false,
    goals: false,
    min_y: -64,
    max_y: 319,
    sea_level: 63,
    border: nil,
    knots: [],
    wet: false,
    zoom_seed: 0,
    tops: nil,
    no_chunks: true
  }
end

# A native section holding the mob of `entry`: the section and the entry.
native_entry = fn id, entry, record ->
  section = %Valimc.Entity.NativeMobs{
    ref: Valimc.Native.mob_section_oracle_new(),
    types: MapSet.new()
  }

  {:ok, [{^id, _, row}]} = Valimc.Native.mob_section_insert(section.ref, [{id, record}], false)
  :ok = Valimc.Native.mob_section_oracle_prepare(section.ref, id, 0.0, nil)
  {section, %{entry | body: row} |> Map.put(:native, section.ref)}
end

[path] = argv
rows = JSON.decode!(File.read!(path))
unless length(rows) == 10, do: raise("Incomplete endermite lifetime fixtures")
view = Valimc.World.View.of(states)

for row <- rows do
  {:ok, body} = Body.new("minecraft:endermite")

  body = %{
    body
    | no_gravity: true,
      data: %{life: row["initial"]},
      mob: %{body.mob | no_ai: true, persistent: row["persistent"]}
  }

  record = Store.body_record(body, <<30::128>>, {0.5, 64.0, 0.5})
  {:ok, store, {_, id, _}} = Store.create_record(Store.new(), {0, 0}, record)
  entry = store.entries[id]
  world = %World{read: fn p -> states[p] end, goals: false}
  {section, entry} = if native?, do: native_entry.(id, entry, record), else: {nil, entry}

  Enum.reduce(row["trace"], entry, fn expected, entry ->
    {[step], _} =
      if native? do
        env = %{region: nil, level: native_level.(true), players: [], items: [], reach: 0}
        MobTicks.native_steps({:states, packed}, [{id, entry}], world, nil, [], section, env)
      else
        MobTicks.steps(view, [{id, entry}], world, nil)
      end

    actual = %{life: step.body.data.life, removed: :discard in step.effects}

    unless actual == %{life: expected["life"], removed: expected["removed"]},
      do: raise("NoAI endermite #{inspect(row)}: #{inspect(actual)} != #{inspect(expected)}")

    %{entry | body: step.body}
  end)
end

IO.puts(
  "PASS: ten native NoAI endermite lifecycle traces through the live mob ticker, persistence and the 2400-tick boundary" <>
    if(native?, do: ", every one a native endermite's", else: "")
)
