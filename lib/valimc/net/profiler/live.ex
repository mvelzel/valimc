defmodule Valimc.Net.Profiler.Live do
  @moduledoc false
  use Phoenix.LiveView, layout: false
  alias Valimc.Admin.Profiler
  alias Valimc.Net.Profiler.{Limits, View}

  @impl true
  def mount(%{"id" => id}, _, socket) do
    with {:ok, report} <- Profiler.report(id),
         :ok <- if(connected?(socket), do: Limits.admit(self()), else: :ok) do
      socket =
        assign(socket,
          id: id,
          report: report,
          tab: if(report.kind == "health", do: "health", else: "tree"),
          query: "",
          group: "",
          sort: "",
          direction: :desc,
          expanded: MapSet.new(),
          zoom: nil,
          theme: "dark",
          expired: false,
          timer: nil
        )

      {:ok, socket |> prepare() |> schedule()}
    else
      _ -> {:ok, assign(socket, expired: true, theme: "dark")}
    end
  end

  @impl true
  def handle_event(_, _, %{assigns: %{expired: true}} = socket), do: {:noreply, socket}

  def handle_event("tab", %{"tab" => tab}, socket) do
    if Enum.any?(View.tabs(), &(elem(&1, 0) == tab)) do
      {:noreply, socket |> assign(tab: tab, sort: "", direction: :desc, zoom: nil) |> prepare()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("filter", params, socket) do
    query = params["query"] || ""
    group = params["group"] || ""

    if is_binary(query) and byte_size(query) <= 128 and
         (group == "" or group in socket.assigns.groups) do
      {:noreply,
       socket
       |> assign(query: query, group: group, zoom: nil, expanded: MapSet.new())
       |> prepare()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("expand", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded

    if Enum.any?(socket.assigns.tree, &(&1.id == id and &1.children)) do
      expanded =
        cond do
          MapSet.member?(expanded, id) -> MapSet.delete(expanded, id)
          MapSet.size(expanded) < 128 -> MapSet.put(expanded, id)
          true -> expanded
        end

      {:noreply, socket |> assign(expanded: expanded) |> prepare()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("zoom", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.flame, &(&1.id == id)) do
      nil -> {:noreply, socket}
      row -> {:noreply, socket |> assign(zoom: row.path) |> prepare()}
    end
  end

  def handle_event("reset", _, socket), do: {:noreply, socket |> assign(zoom: nil) |> prepare()}

  def handle_event("sort", %{"key" => key}, socket) do
    if Enum.any?(socket.assigns.columns, &(Atom.to_string(elem(&1, 0)) == key)) do
      direction =
        if socket.assigns.sort == key and socket.assigns.direction == :desc, do: :asc, else: :desc

      {:noreply, socket |> assign(sort: key, direction: direction) |> prepare()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("theme", _, socket),
    do:
      {:noreply,
       assign(socket, :theme, if(socket.assigns.theme == "dark", do: "light", else: "dark"))}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket) do
    socket = assign(socket, :timer, nil)

    case Profiler.report(socket.assigns.id) do
      {:ok, report} -> {:noreply, socket |> assign(report: report) |> prepare() |> schedule()}
      :error -> {:noreply, assign(socket, :expired, true)}
    end
  end

  defp schedule(socket) do
    if connected?(socket) and socket.assigns.report.status in ["running", "live"] and
         is_nil(socket.assigns.timer) do
      assign(socket, :timer, Process.send_after(self(), :refresh, 2000))
    else
      socket
    end
  end

  defp prepare(socket) do
    a = socket.assigns
    stacks = View.stacks(a.report, a.query, a.group)

    {columns, rows, count} =
      if a.tab in ~w(tree flame),
        do: {[], [], 0},
        else: View.table(a.report, a.tab, a.query, a.group, a.sort, a.direction)

    tree = if a.tab == "tree", do: View.tree(stacks, a.expanded), else: []
    flame = if a.tab == "flame", do: View.flame(stacks, a.zoom), else: []

    assign(socket,
      groups: View.groups(a.report),
      columns: columns,
      rows: rows,
      row_count: count,
      tree: tree,
      flame: flame,
      chart: if(a.tab == "health", do: View.chart(a.report), else: ""),
      mspt_chart: if(a.tab == "health", do: View.chart(a.report, :mspt), else: ""),
      tps_max: if(a.tab == "health", do: View.chart_max(a.report), else: 20),
      mspt_max: if(a.tab == "health", do: View.chart_max(a.report, :mspt), else: 50)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="profile-report" data-theme={@theme}>
      <header class="spark-header">
        <a class="brand" href="#" aria-label="ValiMC profiler"><span aria-hidden="true">⚡</span> ValiMC</a>
        <span class="server-label">ValiMC <span class="muted">/ Elixir · OTP</span></span>
        <button phx-click="theme" aria-label="Toggle color theme" class="theme-toggle">◐</button>
      </header>
      <main :if={@expired}>
        <div class="empty" role="status">Report expired, unknown, or viewer capacity reached. Close an unused viewer and run /spark health or start a new profile.</div>
      </main>
      <main :if={!@expired}>
        <div class="report-heading">
          <span>{if @report.kind == "health", do: "Server health", else: "Performance profile"}</span>
          <span class="muted" id="profile-status" role="status">{@report.status} · {View.format(Map.get(@report, :elapsed_ms, 0) / 1000, :number)}s · {Map.get(@report, :observations, 0)} stack observations</span>
        </div>
        <div class="stats" id="stats">
          <.widget title={View.tps_title(@report)} value={View.format(@report.health.tps, :number)} caption={View.tps_caption(@report)} />
          <.widget :if={Map.has_key?(@report.health, :clock_tps)} title="Clock TPS" value={View.format(@report.health.clock_tps, :number)} caption="World clock · separate" />
          <.widget title="MSPT" value={View.format(@report.health.mspt.p95, :number)} caption="Region ticks · 95%ile" />
          <.widget title="Schedulers" value={View.format(@report.health.scheduler.normal, :percent)} caption="Normal · wall time" />
          <.widget title="Memory" value={View.format(@report.health.memory.total, :memory)} caption="BEAM total" />
          <.widget title="Processes" value={to_string(@report.health.processes)} caption={"#{@report.health.run_queue} in run queue"} />
        </div>
        <div class="controls">
          <div class="profile-meta">
            <span>{Map.get(@report, :started, "Live server dashboard")}</span>
            <small :if={@report.kind == "profile"}>{@report.options.interval} ms interval · {Map.get(@report, :population, 0)} discovered processes</small>
          </div>
          <a class="button" id="download-json" href={"/export/#{@id}/json"} download>Download JSON</a>
          <a class="button" id="download-html" href={"/export/#{@id}/html"} download>Save report</a>
        </div>
        <nav aria-label="Report views" id="tabs">
          <button :for={{id, label} <- View.tabs()} phx-click="tab" phx-value-tab={id} aria-selected={to_string(@tab == id)}>{label}</button>
        </nav>
        <form id="filters" phx-change="filter" phx-submit="filter" class="toolbar">
          <label for="query">Find</label>
          <input id="query" name="query" value={@query} maxlength="128" phx-debounce="200" placeholder="Search for a method, process or counter..." />
          <label for="group">Process group</label>
          <select id="group" name="group">
            <option value="" selected={@group == ""}>All groups</option>
            <option :for={group <- @groups} value={group} selected={@group == group}>{group}</option>
          </select>
        </form>
        <div id="content">
          <div :if={@tab == "tree"} id="call-tree">
            <div :if={@tree == []} class="empty">No stack observations. Keep playing, widen the process filter, or use --include-waiting to inspect idle stacks.</div>
            <div :for={row <- @tree} class="tree-row" style={"padding-left: #{row.depth * 18}px"}>
              <button phx-click="expand" phx-value-id={row.id} disabled={!row.children} aria-expanded={to_string(row.open)} class="tree-label" aria-label={"Expand #{row.name}"} title={"#{row.name} · #{row.count} samples"}>
                <span class="expander">{if row.children, do: if(row.open, do: "▾", else: "▸"), else: "·"}</span>
                <span class="tree-name">{row.name}</span>
                <span class="tree-percent">{View.format(row.percent, :percent)}</span>
                <span class="tree-samples">{row.count} samples</span>
              </button>
              <span class="tree-bar"><i style={"width: #{row.percent}%"}></i></span>
            </div>
            <p :if={length(@tree) == 1000} class="note">Showing 1,000 rows. Collapse branches or narrow the filter.</p>
          </div>
          <div :if={@tab == "flame"} id="flame-graph">
            <button id="reset-zoom" phx-click="reset">Reset zoom</button>
            <p class="note">Click a frame to zoom. Width represents stack observations. Up to 24 levels / 2,000 frames.</p>
            <svg id="flame" viewBox={"0 0 1200 #{max(50, Enum.reduce(@flame, 0, &max(&1.y + 25, &2)))}"} role="group" aria-label="Flame graph">
              <g :for={row <- @flame}>
                <rect x={row.x} y={row.y} width={row.width} height="24" phx-click="zoom" phx-value-id={row.id} tabindex="0" role="button" aria-label={row.name} phx-keydown="zoom" phx-key="Enter">
                  <title>{row.name} · {row.count} samples · {View.format(row.percent, :percent)}</title>
                </rect>
                <text :if={row.width > 40} x={row.x + 5} y={row.y + 16}>{String.slice(row.name, 0, max(1, floor((row.width - 10) / 8)))}</text>
              </g>
            </svg>
          </div>
          <p :if={@tab == "regions"} class="note">Independent region owners. Interval rates, latest duration and lateness; max is since the owner started. Header MSPT uses the last 100 region ticks.</p>
          <p :if={@tab == "memory"} class="note">BEAM rollups overlap. Process heaps exclude shared binaries and allocations inside native resources. ETS tables follow memory categories.</p>
          <p :if={@tab == "hot" and @row_count >= 8192} class="note">Function capacity reached (8,192). Narrow the process or search filter to include other functions.</p>
          <div :if={@tab == "health"} class="health-chart">
            <h2>{View.tps_title(@report)} over time</h2>
            <svg viewBox="0 0 1200 190" role="img" aria-label={View.tps_title(@report) <> " over time"}><path d={@chart} fill="none" stroke="var(--yellow)" stroke-width="2" /></svg>
            <p class="note">0–{View.format(@tps_max, :number)} TPS · {View.tps_caption(@report)}. Missing observations leave gaps.</p>
            <h2>Region p95 MSPT over time</h2>
            <svg viewBox="0 0 1200 190" role="img" aria-label="Region p95 milliseconds per tick over time"><path d={@mspt_chart} fill="none" stroke="var(--yellow)" stroke-width="2" /></svg>
            <p class="note">0–{View.format(@mspt_max, :number)} ms · latest 100 region ticks at each observation. Up to 15 minutes; horizontal position follows elapsed time.</p>
          </div>
          <table :if={@columns != []}>
            <thead><tr><th :for={{key, label, _} <- @columns}><button phx-click="sort" phx-value-key={key}>{label} <span :if={@sort == Atom.to_string(key)}>{if @direction == :desc, do: "↓", else: "↑"}</span></button></th></tr></thead>
            <tbody><tr :for={row <- @rows}><td :for={{key, _, format} <- @columns} title={View.format(Map.get(row, key), format)}>{View.format(Map.get(row, key), format)}</td></tr></tbody>
          </table>
          <p :if={@row_count > 500} class="note">Showing 500 of {@row_count} rows. Use Find to narrow the results.</p>
        </div>
        <footer>Stack samples are BEAM process observations; reductions rank process work separately. Rust internals are not resolved. Waiting stacks are included only when requested. {Map.get(@report, :dropped, 0)} observations dropped at capacity.</footer>
      </main>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:value, :string, required: true)
  attr(:caption, :string, required: true)

  defp widget(assigns) do
    ~H"""
    <div class="stat"><h2>{@title}</h2><strong>{@value}</strong><span>{@caption}</span></div>
    """
  end
end
