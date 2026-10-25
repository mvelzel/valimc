defmodule Valimc.Commands.Spark do
  @moduledoc "Spark-style operator commands for BEAM profiling; see docs/profiling.md."
  alias Valimc.Admin.Profiler
  alias Valimc.Commands.Feedback
  alias Valimc.Commands.Parser.Tree
  alias Valimc.Commands.Parser.Tree.Node
  alias Valimc.Text
  alias Valimc.Commands.SparkStyle, as: Style

  def tree do
    # Reuse the pinned codec's greedy string descriptor; no second parser table.
    help = Enum.find(Tree.vanilla(), &(&1["name"] == "help"))
    parser = hd(help["children"])
    root = literal("spark", ["spark"], 3)

    children =
      for name <-
            ~w(health tps ping tickmonitor heapsummary processes ets schedulers gc activity help),
          do: literal(name, ["spark", name])

    profiler = literal("profiler", ["spark", "profiler"])

    profiler = %{
      profiler
      | children:
          for name <- ~w(start stop cancel info open) do
            node = literal(name, profiler.path ++ [name])
            if name == "start", do: %{node | children: [argument(node.path, parser)]}, else: node
          end
    }

    children =
      Enum.map(children, fn node ->
        if node.name in ~w(health processes tickmonitor),
          do: %{node | children: [argument(node.path, parser)]},
          else: node
      end)

    %{root | children: [profiler | children]}
  end

  defp literal(name, path, level \\ 0),
    do: %Node{
      name: name,
      path: path,
      type: :literal,
      level: level,
      restricted: level > 0,
      command: "spark"
    }

  defp argument(path, parser),
    do: %Node{
      name: "options",
      path: path ++ ["options"],
      type: :argument,
      level: 0,
      restricted: false,
      command: "spark",
      parser: parser["parser"],
      parser_id: parser["parser_id"],
      properties: parser["properties"],
      bytes: Base.decode16!(parser["bytes"], case: :lower)
    }

  def run(arguments, source) do
    dispatch(arguments[:literals] || [], Map.get(arguments, "options", ""), source)
    1
  end

  defp dispatch(["profiler", "start"], flags, source) do
    with {:ok, options} <- Profiler.options(String.split(flags)),
         {:ok, id} <- Profiler.start(options, &completed(source, &1)) do
      say(
        source,
        Style.text("Profiler is now running!", "gold")
        |> Text.append(Style.text(" (BEAM sampler)", "dark_gray"))
      )

      say(
        source,
        "The results will be automatically returned after the profiler has been running for #{options.timeout} seconds."
      )

      link(source, id)
    else
      {:error, message} -> fail(source, message)
    end
  end

  defp dispatch(["profiler", "stop"], _, source), do: completed(source, Profiler.stop())

  defp dispatch(["profiler", "cancel"], _, source) do
    :ok = Profiler.cancel()
    say(source, Style.text("Profiler has been cancelled.", "gold"))
  end

  defp dispatch(["profiler", action], _, source) when action in ["open", "info"] do
    case Profiler.info() do
      nil ->
        say(source, "The profiler isn't running!")
        say(source, "To start a new one, run:")
        say(source, Style.prompt("/spark profiler start"))

      info ->
        say(source, Style.text("Profiler is already running!", "gold"))
        say(source, "It has been running for #{Float.round(info.elapsed / 1000, 1)} seconds.")
        link(source, info.id)
    end
  end

  defp dispatch(["health"], "", source) do
    say(source, "Generating server health report...")
    {:ok, id} = Profiler.health_report()
    say(source, Style.text("Health Report:", "gold"))
    link(source, id)
  end

  defp dispatch(["health"], "show", source) do
    health = Profiler.health()
    say(source, "Generating server health report...")
    tps(source, health)
    say(source, "")
    say(source, "BEAM memory usage:")

    say(
      source,
      Style.text(" ")
      |> Text.append(Style.text("#{mib(health.memory.total)} MiB", "yellow"))
      |> Text.append(
        Style.text(
          "  (#{health.processes} processes; #{health.run_queue} in run queue)",
          "dark_gray"
        )
      )
    )
  end

  defp dispatch(["tps"], _, source), do: tps(source, Profiler.health())

  defp dispatch(["schedulers"], _, source) do
    h = Profiler.health()

    say(source, "Scheduler utilization (wall time):")

    for {key, label} <- [normal: "normal", dirty_cpu: "dirty CPU", dirty_io: "dirty IO"],
        do:
          say(
            source,
            Style.values([Style.utilization(h.scheduler[key])])
            |> Text.append(Style.text("  (#{label})", "dark_gray"))
          )

    say(source, Style.text(" Run queue: #{h.run_queue}", "gray"))
  end

  defp dispatch(["gc"], _, source) do
    gc = Profiler.health().gc

    say(
      source,
      "BEAM GC since boot: #{gc.collections} collections · #{gc.reclaimed_words} reclaimed words. Collections are per-process; these are counts, not pause times."
    )
  end

  defp dispatch(["heapsummary"], _, source) do
    h = Profiler.health()

    say(
      source,
      "BEAM memory: processes #{mib(h.memory.processes)} MiB · binaries #{mib(h.memory.binary)} MiB · ETS #{mib(h.memory.ets)} MiB · code #{mib(h.memory.code)} MiB"
    )

    {:ok, id} = Profiler.health_report()
    link(source, id)
  end

  defp dispatch(["ets"], _, source) do
    for row <- Enum.take(Profiler.health().ets, 8),
        do: say(source, "#{row.name}: #{mib(row.bytes)} MiB · #{row.size} objects")
  end

  defp dispatch(["processes"], sort, source)
       when sort in ["", "--sort memory", "--sort mailbox", "--sort reductions"] do
    case Profiler.info() do
      nil ->
        say(
          source,
          "Start /spark profiler start to collect process reductions, memory and mailboxes."
        )

      %{id: id} ->
        {:ok, data} = Profiler.report(id)

        key =
          %{
            "" => :reductions,
            "--sort memory" => :memory,
            "--sort mailbox" => :mailbox,
            "--sort reductions" => :reductions
          }[sort]

        for row <- data.processes |> Enum.sort_by(&(-Map.fetch!(&1, key))) |> Enum.take(8),
            do:
              say(
                source,
                "#{row.pid} #{row.name}: #{row.reductions} reductions · #{mib(row.memory)} MiB · mailbox #{row.mailbox}"
              )
    end
  end

  defp dispatch(["ping"], _, source) do
    pings = Valimc.Data.ProfileTicks.pings()

    values =
      for player <- Valimc.Player.PlayerList.all(), ms = pings[player.pid], ms != nil, do: ms

    case values do
      [] ->
        say(source, "No player RTT samples yet; waiting for keepalive replies.")

      values ->
        values = Enum.sort(values)
        say(source, "Ping (min/med/95%ile/max ms):")

        say(
          source,
          Style.values(
            Enum.map(
              [
                hd(values),
                Profiler.median(values),
                Enum.at(values, max(0, ceil(length(values) * 0.95) - 1)),
                List.last(values)
              ],
              &Style.ping/1
            ),
            "/"
          )
        )
    end
  end

  defp dispatch(["tickmonitor"], flags, source) do
    threshold =
      case String.split(flags) do
        [] ->
          {:ok, 50}

        ["--threshold-tick", value] ->
          case Integer.parse(value) do
            {n, ""} when n in 10..10_000 -> {:ok, n}
            _ -> :error
          end

        _ ->
          :error
      end

    case threshold do
      {:ok, ms} ->
        key =
          case source.sink do
            {:player, pid} -> pid
            _ -> :console
          end

        case Profiler.monitor(key, ms, &say(source, &1)) do
          {:ok, enabled} ->
            say(
              source,
              "Tick monitor #{if(enabled, do: "enabled (#{ms}ms; 10 minute limit)", else: "disabled")}."
            )

          {:error, message} ->
            fail(source, message)
        end

      :error ->
        fail(source, "Use /spark tickmonitor [--threshold-tick 10..10000]")
    end
  end

  defp dispatch(["activity"], _, source), do: Enum.each(Profiler.activity(), &say(source, &1))

  defp dispatch(_, _, source) do
    say(
      source,
      "/spark profiler start [--timeout 60] [--interval 20] [--process Valimc.World] [--include-waiting]"
    )

    say(
      source,
      "/spark profiler stop|cancel|info|open · /spark health [show] · /spark tps · /spark tickmonitor"
    )

    say(
      source,
      "/spark processes [--sort memory|mailbox|reductions] · /spark heapsummary · /spark ets · /spark schedulers · /spark gc · /spark activity"
    )
  end

  defp tps(source, h) do
    windows = h.windows
    say(source, "Simulation TPS (slowest region), last 5s, 10s, 1m, 5m, 15m:")
    say(source, Style.values(Enum.map(windows, &Style.tps(&1.tps, h.tick_state.rate))))
    say(source, "World clock TPS (separate):")
    say(source, Style.values(Enum.map(windows, &Style.tps(&1.clock_tps, h.tick_state.rate))))
    say(source, "")
    say(source, "Region tick durations (min/med/95%ile/max ms), latest 100:")

    say(
      source,
      Style.values(
        Enum.map(
          [h.mspt.min, h.mspt.median, h.mspt.p95, h.mspt.max],
          &Style.duration(&1, 1000 / h.tick_state.rate)
        ),
        "/"
      )
    )

    say(source, "")
    say(source, "Scheduler usage from last 10s, 1m, 15m:")

    for {key, label} <- [normal: "normal", dirty_cpu: "dirty CPU", dirty_io: "dirty IO"] do
      values =
        windows
        |> Enum.filter(&(&1.seconds in [10, 60, 900]))
        |> Enum.map(&Style.utilization(&1.scheduler[key]))

      say(source, Style.values(values) |> Text.append(Style.text("  (#{label})", "dark_gray")))
    end
  end

  defp completed(source, {:ok, id}),
    do:
      (
        say(source, Style.text("Profiler stopped & save complete!", "gold"))
        link(source, id)
      )

  defp completed(source, {:error, message}), do: fail(source, message)

  defp link(source, id) do
    url = Profiler.url(id)
    Feedback.success(source, Style.url(url), false)
  end

  defp say(source, line), do: Feedback.success(source, Style.prefix(line), false)

  defp fail(source, line),
    do: Feedback.success(source, Style.prefix(Style.text(line, "red")), false)

  defp fixed(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp mib(n), do: fixed(n / 1_048_576)
end
