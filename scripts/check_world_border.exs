# Replays WorldBorderOracle's scripts on Valimc.World.Border (VMC-027b) and its
# /worldborder sequences through the command module (VMC-027c).
#
#   mix run --no-start scripts/check_world_border.exs kernel KERNEL.json
#   mix run --no-start scripts/check_world_border.exs commands COMMANDS.json
alias Valimc.Text.Error
alias Valimc.Commands.Source
alias Valimc.Text
alias Valimc.Commands.WorldBorder, as: Command
alias Valimc.Protocol.{Packets, Wire}
alias Valimc.World.{Border, BorderReplication}

defmodule Check do
  def bits(value), do: Base.encode16(<<value::float-64>>, case: :lower)

  def hex({id, body}),
    do: IO.iodata_to_binary([Wire.varint(id), body]) |> Base.encode16(case: :lower)

  def same!(label, actual, expected) do
    unless actual == expected,
      do: raise("#{label} differs:\n  valimc  #{inspect(actual)}\n  vanilla #{inspect(expected)}")
  end

  def state!(label, border, expected) do
    {a, c, b, d} = Border.bounds(border)
    same!("#{label} size", bits(Border.size(border)), expected["size"])
    same!("#{label} target", bits(Border.lerp_target(border)), expected["target"])
    same!("#{label} lerp time", Border.lerp_time(border), expected["lerp_time"])
    same!("#{label} status", Atom.to_string(Border.status(border)), expected["status"])
    same!("#{label} bounds", Enum.map([a, c, b, d], &bits/1), expected["bounds"])

    <<x::float-64, z::float-64, damage::float-64, safe::float-64, blocks::signed-32,
      time::signed-32, size::float-64, ticks::signed-64, target::float-64>> =
      Border.encode(border)

    same!(
      "#{label} settings",
      [bits(x), bits(z), bits(damage), bits(safe), blocks, time, bits(size), ticks, bits(target)],
      expected["settings"]
    )

    same!(
      "#{label} initialize",
      hex(BorderReplication.initialize(border)),
      expected["initialize"]
    )

    physics = Border.physics(border)

    for point <- expected["points"] do
      <<px::float-64>> = Base.decode16!(point["x"], case: :lower)
      <<pz::float-64>> = Base.decode16!(point["z"], case: :lower)
      same!("#{label} inside #{px},#{pz}", Border.within?(border, px, pz), point["inside"])

      same!(
        "#{label} distance #{px},#{pz}",
        bits(Border.distance(border, px, pz)),
        point["distance"]
      )

      same!("#{label} damage #{px},#{pz}", Border.damage(physics, px, pz), point["damage"])
    end
  end

  # A system chat packet as `{id, component, overlay}`: compound key order is free.
  def chat(hex) do
    bytes = Base.decode16!(hex, case: :lower)
    {:ok, id, rest} = Wire.read_varint(bytes)
    {:ok, tag, overlay} = Valimc.Data.NBT.take(rest)
    {id, tag, overlay}
  end

  def packets(before, border) do
    {_, packets} = BorderReplication.reconcile(before, border)
    Enum.map(packets, &hex/1)
  end
end

case System.argv() do
  ["kernel", path] ->
    scripts = path |> File.read!() |> JSON.decode!()

    steps =
      for [start | steps] <- scripts, reduce: 0 do
        count ->
          border = Border.new()
          Check.state!("start", border, start["state"])

          Enum.reduce(steps, border, fn step, border ->
            game_time = step["game_time"]

            next =
              case String.split(step["op"], " ") do
                ["tick", n] ->
                  Enum.reduce(1..String.to_integer(n), border, fn _, b -> Border.tick(b) end)

                ["size", s] ->
                  Border.set_size(border, Float.parse(s) |> elem(0))

                ["lerp", from, to, ticks] ->
                  Border.lerp(
                    border,
                    Float.parse(from) |> elem(0),
                    Float.parse(to) |> elem(0),
                    String.to_integer(ticks),
                    game_time
                  )

                ["center", x, z] ->
                  Border.set_center(border, Float.parse(x) |> elem(0), Float.parse(z) |> elem(0))

                ["damage", v] ->
                  Border.set_damage_per_block(border, Float.parse(v) |> elem(0))

                ["safe", v] ->
                  Border.set_safe_zone(border, Float.parse(v) |> elem(0))

                ["warning_time", t] ->
                  Border.set_warning_time(border, String.to_integer(t))

                ["warning_blocks", n] ->
                  Border.set_warning_blocks(border, String.to_integer(n))

                ["absolute", m] ->
                  %{border | absolute_max: String.to_integer(m)}

                ["reload"] ->
                  {:ok, loaded} = Border.decode(Border.encode(border), game_time)
                  %{loaded | absolute_max: border.absolute_max}
              end

            unless step["op"] == "reload",
              do:
                Check.same!("#{step["op"]} packets", Check.packets(border, next), step["events"])

            Check.state!(step["op"], next, step["state"])
            next
          end)

          count + length(steps)
      end

    IO.puts(
      "PASS: #{length(scripts)} world border scripts / #{steps} steps match size, lerp, bounds, settings, packets and damage."
    )

  ["commands", path] ->
    sequences = path |> File.read!() |> JSON.decode!()
    source = %Source{Source.parse_only(4) | position: {10.5, 64.0, -3.25}}

    inputs =
      for rows <- sequences, reduce: 0 do
        count ->
          Enum.reduce(rows, Border.new(), fn row, border ->
            input = row["input"]

            next =
              case input do
                "#tick " <> n ->
                  Enum.reduce(1..String.to_integer(n), border, fn _, b -> Border.tick(b) end)

                _ ->
                  {:ok, {Command, :worldborder}, arguments, _} =
                    Valimc.Commands.parse(input, source)

                  function = Command.kind(arguments.literals)

                  {next, messages, result} =
                    if function == :get do
                      {component, result} = Command.query(border)
                      {border, [{component, false}], result}
                    else
                      operation = Command.operation(function, arguments, source.position)

                      case Border.command(border, operation, row["game_time"]) do
                        {:ok, next, outcome} ->
                          {component, result} = Command.success(operation, outcome)
                          {next, [{component, true}], result}

                        {:error, reason} ->
                          {border, [{Error.failure(Command.failure(reason)), false}], nil}
                      end
                    end

                  expected =
                    for m <- row["messages"], do: {Check.chat(m["packet"]), m["broadcast"]}

                  actual =
                    for {component, broadcast} <- messages,
                        do:
                          {Check.chat(Check.hex(Packets.chat(Text.encode(component)))), broadcast}

                  Check.same!("/#{input} feedback", actual, expected)
                  Check.same!("/#{input} result", result, row["result"])
                  Check.same!("/#{input} packets", Check.packets(border, next), row["events"])
                  next
              end

            Check.state!("/#{input}", next, row["state"])
            next
          end)

          count + length(rows)
      end

    IO.puts(
      "PASS: #{length(sequences)} /worldborder sequences / #{inputs} inputs match feedback, results, packets and border state."
    )
end
