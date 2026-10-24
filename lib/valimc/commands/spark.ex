defmodule Valimc.Commands.Spark do
  @moduledoc "Spark-style operator commands for BEAM profiling; see docs/profiling.md."
  alias Valimc.Admin.Profiler
  alias Valimc.Commands.Feedback
  alias Valimc.Commands.Parser.Tree
  alias Valimc.Commands.Parser.Tree.Node
  alias Valimc.Text

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
        "Profiler started (#{options.timeout}s, #{options.interval}ms). Keep playing, then /spark profiler stop."
      )

      link(source, id)
    else
      {:error, message} -> fail(source, message)
    end
  end

  defp dispatch(["profiler", "stop"], _, source), do: completed(source, Profiler.stop())

  defp dispatch(["profiler", "cancel"], _, source) do
    :ok = Profiler.cancel()
    say(source, "Profile cancelled.")
  end

  defp dispatch(["profiler", action], _, source) when action in ["open", "info"] do
    case Profiler.info() do
      nil ->
        say(source, "No profile is running. Start one with /spark profiler start --timeout 60")

      info ->
        say(source, "Profiler running for #{Float.round(info.elapsed / 1000, 1)}s.")
        link(source, info.id)
    end
  end

  defp dispatch(["health"], flags, source) when flags in ["", "show"] do
    health = Profiler.health()

    say(
      source,
      "BEAM: #{health.processes} processes · #{mib(health.memory.total)} MiB · run queue #{health.run_queue}"
    )

    tps(source, health)
    {:ok, id} = Profiler.health_report()
    link(source, id)
  end

  defp dispatch(["tps"], _, source), do: tps(source, Profiler.health())

  defp dispatch(["schedulers"], _, source) do
    h = Profiler.health()

    say(
      source,
      "Scheduler utilization: normal #{fixed(h.scheduler.normal)}% · dirty CPU #{fixed(h.scheduler.dirty_cpu)}% · dirty IO #{fixed(h.scheduler.dirty_io)}% · run queue #{h.run_queue}"
    )
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
        say(
          source,
          "Player RTT: #{length(values)} measured · mean #{fixed(Enum.sum(values) / length(values))}ms · min/max #{Enum.min(values)}/#{Enum.max(values)}ms"
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
    say(
      source,
      "Clock: #{fixed(h.tps)} TPS (target #{h.tick_state.rate}#{if(h.tick_state.frozen, do: ", frozen", else: "")}) · region MSPT mean/p95/max: #{fixed(h.mspt.mean)}/#{fixed(h.mspt.p95)}/#{fixed(h.mspt.max)}"
    )
  end

  defp completed(source, {:ok, id}),
    do:
      (
        say(source, "Profile complete and saved locally.")
        link(source, id)
      )

  defp completed(source, {:error, message}), do: fail(source, message)

  defp link(source, id) do
    url = Profiler.url(id)
    click = {:compound, %{"action" => {:string, "open_url"}, "url" => {:string, url}}}

    Feedback.success(
      source,
      Text.literal("[spark] #{url}")
      |> Text.style([{"color", "aqua"}, {"underlined", true}, {"click_event", click}]),
      false
    )
  end

  defp say(source, line), do: Feedback.success(source, Text.literal("[spark] " <> line), false)
  defp fail(source, line), do: Feedback.failure(source, Text.literal("[spark] " <> line))
  defp fixed(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp mib(n), do: fixed(n / 1_048_576)
end
