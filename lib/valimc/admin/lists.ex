defmodule Valimc.Admin.Lists do
  @moduledoc """
  Operators, the whitelist, player and IP bans and the name cache (VMC-010a),
  vanilla's `PlayerList` user lists and `UserNameToIdResolver`.

  One owner holds the lists and writes their files in the world directory
  (`Valimc.Admin.ListFile`) when a command changes them; the name cache is
  written at most once a second. Logins and permission checks read the
  published ETS rows without calling the owner: `{:op, uuid}`,
  `{:white, uuid}`, `{:ban, uuid}`, `{:ip_ban, ip}` and the `:white_list` and
  `:enforce_whitelist` switches. Each change updates only the rows it touches,
  so a reader never sees a list half replaced.

  Names in `VALIMC_OPERATORS` are added to `ops.json` at startup; in online mode
  a name not yet in the name cache becomes an operator at its first login.
  Profiles are not looked up at Mojang: in online mode only players who have
  joined resolve by name.
  """
  use GenServer
  alias Valimc.Admin.ListFile

  @table __MODULE__
  @month 30 * 24 * 3600
  @cache_size 1000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ---- readers (no owner call) ----

  defp lookup(key) do
    case :ets.whereis(@table) do
      :undefined -> nil
      _ -> with [row] <- :ets.lookup(@table, key), do: row, else: (_ -> nil)
    end
  end

  @doc "The op entry's `{level, bypasses_player_limit}` for a UUID, or nil."
  def op(uuid) do
    case lookup({:op, uuid}) do
      {_, _name, level, bypass} -> {level, bypass}
      nil -> nil
    end
  end

  def whitelisted?(uuid), do: lookup({:white, uuid}) != nil
  def white_list?, do: match?({_, true}, lookup(:white_list))

  @doc "The player idle timeout in minutes (vanilla's `player-idle-timeout`); 0 is off."
  def idle_timeout do
    case lookup(:idle_timeout) do
      {_, minutes} -> minutes
      nil -> 0
    end
  end

  def enforce_whitelist?, do: match?({_, true}, lookup(:enforce_whitelist))

  @doc "An active (unexpired) ban for a UUID or IP, or nil."
  def ban(uuid), do: active(lookup({:ban, uuid}))
  def ip_ban(ip), do: active(lookup({:ip_ban, ip}))

  defp active({_, entry}), do: if(expired?(entry), do: nil, else: entry)
  defp active(nil), do: nil

  defp expired?(%{"expires" => "forever"}), do: false

  defp expired?(%{"expires" => text}) do
    case ListFile.parse_date(text) do
      {:ok, at} -> at < System.os_time(:second)
      :error -> false
    end
  end

  defp expired?(_), do: false

  # ---- owner calls ----

  @doc "Resolves a typed name to `{:ok, %{uuid, name}}` or `:unknown` (`argument.player.unknown`)."
  def resolve(name), do: GenServer.call(__MODULE__, {:resolve, name})

  @doc "A login: remember the profile in the name cache (and grant pending operators)."
  def remember(uuid, name), do: GenServer.cast(__MODULE__, {:remember, uuid, name})

  def add_ops(profiles, level), do: GenServer.call(__MODULE__, {:add_ops, profiles, level})
  def remove_ops(profiles), do: GenServer.call(__MODULE__, {:remove_ops, profiles})
  def ban_players(profiles, entry), do: GenServer.call(__MODULE__, {:ban, profiles, entry})
  def pardon_players(profiles), do: GenServer.call(__MODULE__, {:pardon, profiles})
  def ban_ip(ip, entry), do: GenServer.call(__MODULE__, {:ban_ip, ip, entry})
  def pardon_ip(ip), do: GenServer.call(__MODULE__, {:pardon_ip, ip})
  def whitelist_add(profiles), do: GenServer.call(__MODULE__, {:whitelist_add, profiles})
  def whitelist_remove(profiles), do: GenServer.call(__MODULE__, {:whitelist_remove, profiles})
  def set_white_list(on), do: GenServer.call(__MODULE__, {:white_list, on})
  def set_idle_timeout(minutes), do: GenServer.call(__MODULE__, {:idle_timeout, minutes})
  def reload_whitelist, do: GenServer.call(__MODULE__, :reload_whitelist)

  @doc "`{kind, entries}` snapshots for listing and suggestions."
  def entries(kind) when kind in [:ops, :whitelist, :bans, :ip_bans],
    do: GenServer.call(__MODULE__, {:entries, kind})

  @doc "A new ban entry created now, in vanilla's field order."
  def ban_entry(source, reason) do
    [{"created", ListFile.now_text()}, {"source", source}, {"expires", "forever"}] ++
      if(reason, do: [{"reason", reason}], else: [])
  end

  # ---- owner ----

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    dir = Keyword.get(opts, :dir, Valimc.config(:world_path))

    state = %{
      table: table,
      dir: dir,
      ops: %{},
      whitelist: %{},
      bans: %{},
      ip_bans: %{},
      cache: %{},
      pending_ops: MapSet.new(),
      cache_timer: nil,
      settings: settings(dir)
    }

    state =
      state
      |> load(:bans)
      |> load(:ip_bans)
      |> load(:ops)
      |> load(:whitelist)
      |> load_cache()

    for kind <- [:bans, :ip_bans, :ops], do: save(state, kind)
    if dir && not File.exists?(file(dir, :whitelist)), do: save(state, :whitelist)

    :ets.insert(@table, [
      {:idle_timeout, state.settings.idle_timeout},
      {:white_list, state.settings.white_list},
      {:enforce_whitelist, state.settings.enforce_whitelist}
    ])

    {:ok, seed_operators(state)}
  end

  # The switches are ValiMC settings (vanilla keeps them in `server.properties`);
  # `/whitelist on|off` saves its choice in `admin-settings.json`.
  defp settings(dir) do
    saved =
      with dir when is_binary(dir) <- dir,
           {:ok, text} <- File.read(Path.join(dir, "admin-settings.json")),
           {:ok, map} when is_map(map) <- JSON.decode(text) do
        map
      else
        _ -> %{}
      end

    idle =
      case saved["player-idle-timeout"] do
        minutes when is_integer(minutes) and minutes >= 0 -> minutes
        _ -> Valimc.config(:player_idle_timeout)
      end

    %{
      white_list: Map.get(saved, "white-list", Valimc.config(:white_list) == true),
      enforce_whitelist: Valimc.config(:enforce_whitelist) == true,
      idle_timeout: idle
    }
  end

  defp save_settings(%{dir: nil}), do: :ok

  defp save_settings(state) do
    File.mkdir_p!(state.dir)
    path = Path.join(state.dir, "admin-settings.json")

    File.write!(
      path <> ".tmp",
      JSON.encode!(%{
        "white-list" => state.settings.white_list,
        "player-idle-timeout" => state.settings.idle_timeout
      })
    )

    File.rename!(path <> ".tmp", path)
  end

  defp seed_operators(state) do
    case Valimc.config(:operators) do
      names when is_list(names) ->
        Enum.reduce(names, state, fn name, state ->
          case profile_for(state, name, false) do
            {:ok, profile, state} ->
              if Map.has_key?(state.ops, profile.uuid),
                do: state,
                else: elem(put_ops(state, [profile], Valimc.config(:operator_level)), 1)

            :unknown ->
              %{state | pending_ops: MapSet.put(state.pending_ops, String.downcase(name))}
          end
        end)

      _ ->
        state
    end
  end

  @impl true
  def handle_call({:resolve, name}, _from, state) do
    case profile_for(state, name, true) do
      {:ok, profile, state} -> {:reply, {:ok, profile}, state}
      :unknown -> {:reply, :unknown, state}
    end
  end

  def handle_call({:add_ops, profiles, level}, _from, state) do
    {changed, state} =
      put_ops(state, Enum.reject(profiles, &Map.has_key?(state.ops, &1.uuid)), level)

    {:reply, changed, state}
  end

  def handle_call({:remove_ops, profiles}, _from, state) do
    changed = Enum.filter(profiles, &Map.has_key?(state.ops, &1.uuid))
    for profile <- changed, do: :ets.delete(@table, {:op, profile.uuid})
    state = %{state | ops: Map.drop(state.ops, Enum.map(changed, & &1.uuid))}
    if changed != [], do: save(state, :ops)
    {:reply, changed, state}
  end

  def handle_call({:ban, profiles, entry}, _from, state) do
    changed =
      profiles
      |> Enum.reject(&(Map.has_key?(state.bans, &1.uuid) and ban(&1.uuid) != nil))
      |> Enum.uniq_by(& &1.uuid)

    bans =
      Enum.reduce(changed, state.bans, fn profile, bans ->
        entry = Map.new([{"name", profile.name} | entry])
        :ets.insert(@table, {{:ban, profile.uuid}, entry})
        Map.put(bans, profile.uuid, entry)
      end)

    state = %{state | bans: bans}
    if changed != [], do: save(state, :bans)
    {:reply, changed, state}
  end

  def handle_call({:pardon, profiles}, _from, state) do
    changed = profiles |> Enum.filter(&(ban(&1.uuid) != nil)) |> Enum.uniq_by(& &1.uuid)
    for profile <- changed, do: :ets.delete(@table, {:ban, profile.uuid})
    state = %{state | bans: Map.drop(state.bans, Enum.map(changed, & &1.uuid))}
    if changed != [], do: save(state, :bans)
    {:reply, changed, state}
  end

  def handle_call({:ban_ip, ip, entry}, _from, state) do
    if ip_ban(ip) != nil do
      {:reply, :already, state}
    else
      entry = Map.new(entry)
      :ets.insert(@table, {{:ip_ban, ip}, entry})
      state = %{state | ip_bans: Map.put(state.ip_bans, ip, entry)}
      save(state, :ip_bans)
      {:reply, :ok, state}
    end
  end

  def handle_call({:pardon_ip, ip}, _from, state) do
    if ip_ban(ip) == nil do
      {:reply, :not_banned, state}
    else
      :ets.delete(@table, {:ip_ban, ip})
      state = %{state | ip_bans: Map.delete(state.ip_bans, ip)}
      save(state, :ip_bans)
      {:reply, :ok, state}
    end
  end

  def handle_call({:whitelist_add, profiles}, _from, state) do
    changed =
      profiles |> Enum.reject(&Map.has_key?(state.whitelist, &1.uuid)) |> Enum.uniq_by(& &1.uuid)

    for profile <- changed, do: :ets.insert(@table, {{:white, profile.uuid}, profile.name})

    state = %{
      state
      | whitelist: Map.merge(state.whitelist, Map.new(changed, &{&1.uuid, &1.name}))
    }

    if changed != [], do: save(state, :whitelist)
    {:reply, changed, state}
  end

  def handle_call({:whitelist_remove, profiles}, _from, state) do
    changed =
      profiles |> Enum.filter(&Map.has_key?(state.whitelist, &1.uuid)) |> Enum.uniq_by(& &1.uuid)

    for profile <- changed, do: :ets.delete(@table, {:white, profile.uuid})
    state = %{state | whitelist: Map.drop(state.whitelist, Enum.map(changed, & &1.uuid))}
    if changed != [], do: save(state, :whitelist)
    {:reply, changed, state}
  end

  def handle_call({:white_list, on}, _from, %{settings: %{white_list: on}} = state),
    do: {:reply, :unchanged, state}

  def handle_call({:white_list, on}, _from, state) do
    state = put_in(state.settings.white_list, on)
    :ets.insert(@table, {:white_list, on})
    save_settings(state)
    {:reply, :ok, state}
  end

  def handle_call({:idle_timeout, minutes}, _from, state) do
    state = put_in(state.settings.idle_timeout, minutes)
    :ets.insert(@table, {:idle_timeout, minutes})
    save_settings(state)
    {:reply, :ok, state}
  end

  # A missing or unreadable file leaves the list unchanged, as in vanilla.
  def handle_call(:reload_whitelist, _from, state) do
    previous = state.whitelist
    state = load(state, :whitelist)

    for uuid <- Map.keys(previous),
        not Map.has_key?(state.whitelist, uuid),
        do: :ets.delete(@table, {:white, uuid})

    {:reply, :ok, state}
  end

  def handle_call({:entries, kind}, _from, state), do: {:reply, Map.fetch!(state, kind), state}

  @impl true
  def handle_cast({:remember, uuid, name}, state) do
    state = cache(state, %{uuid: uuid, name: name})
    key = String.downcase(name)

    state =
      if MapSet.member?(state.pending_ops, key) and not Map.has_key?(state.ops, uuid) do
        {_, state} = put_ops(state, [%{uuid: uuid, name: name}], Valimc.config(:operator_level))
        %{state | pending_ops: MapSet.delete(state.pending_ops, key)}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:save_cache, state) do
    entries =
      state.cache
      |> Map.values()
      |> Enum.sort_by(& &1.used, :desc)
      |> Enum.map(fn entry ->
        [
          {"uuid", ListFile.uuid_string(entry.uuid)},
          {"name", entry.name},
          {"expiresOn", ListFile.format(entry.expires)}
        ]
      end)

    if state.dir, do: ListFile.write_compact(file(state.dir, :cache), entries)
    {:noreply, %{state | cache_timer: nil}}
  end

  # ---- profiles ----

  # `UserNameToIdResolver` order: a cached, unexpired name; then (offline mode)
  # an offline profile of the lower-cased name, which is cached too.
  defp profile_for(state, name, cache?) do
    key = String.downcase(name)
    now = System.os_time(:second)

    case state.cache[key] do
      %{expires: expires} = entry when expires > now ->
        {:ok, %{uuid: entry.uuid, name: entry.name},
         if(cache?, do: cache(state, entry), else: state)}

      _ ->
        cond do
          Valimc.config(:online_mode) ->
            :unknown

          cache? ->
            profile = %{uuid: Valimc.Connection.offline_uuid(key), name: key}
            {:ok, profile, cache(state, profile)}

          true ->
            # Seeded operators keep their configured spelling, which is the name
            # the player logs in with.
            {:ok, %{uuid: Valimc.Connection.offline_uuid(name), name: name}, state}
        end
    end
  end

  defp cache(state, profile) do
    now = System.os_time(:second)

    entry = %{
      uuid: profile.uuid,
      name: profile.name,
      expires: now + @month,
      used: System.unique_integer([:monotonic])
    }

    cache =
      state.cache
      |> Map.reject(fn {_, cached} -> cached.uuid == profile.uuid end)
      |> Map.put(String.downcase(profile.name), entry)

    cache =
      if map_size(cache) > @cache_size,
        do:
          cache
          |> Enum.sort_by(fn {_, e} -> e.used end, :desc)
          |> Enum.take(@cache_size)
          |> Map.new(),
        else: cache

    timer = state.cache_timer || Process.send_after(self(), :save_cache, 1000)
    %{state | cache: cache, cache_timer: timer}
  end

  defp put_ops(state, profiles, level) do
    profiles = Enum.uniq_by(profiles, & &1.uuid)

    ops =
      Enum.reduce(profiles, state.ops, fn profile, ops ->
        :ets.insert(@table, {{:op, profile.uuid}, profile.name, level, false})
        Map.put(ops, profile.uuid, %{name: profile.name, level: level, bypass: false})
      end)

    state = %{state | ops: ops}
    if profiles != [], do: save(state, :ops)
    {profiles, state}
  end

  # ---- files ----

  defp file(dir, :ops), do: Path.join(dir, "ops.json")
  defp file(dir, :whitelist), do: Path.join(dir, "whitelist.json")
  defp file(dir, :bans), do: Path.join(dir, "banned-players.json")
  defp file(dir, :ip_bans), do: Path.join(dir, "banned-ips.json")
  defp file(dir, :cache), do: Path.join(dir, "usercache.json")

  defp load(%{dir: nil} = state, _kind), do: state

  defp load(state, kind) do
    case ListFile.read(file(state.dir, kind)) do
      {:ok, entries} ->
        loaded = entries |> Enum.flat_map(&decode(kind, &1)) |> Map.new()
        publish(kind, loaded)
        Map.put(state, kind, loaded)

      :missing ->
        state
    end
  end

  defp publish(:ops, ops),
    do:
      :ets.insert(@table, for({uuid, op} <- ops, do: {{:op, uuid}, op.name, op.level, op.bypass}))

  defp publish(:whitelist, list),
    do: :ets.insert(@table, for({uuid, name} <- list, do: {{:white, uuid}, name}))

  defp publish(:bans, bans),
    do: :ets.insert(@table, for({uuid, entry} <- bans, do: {{:ban, uuid}, entry}))

  defp publish(:ip_bans, bans),
    do: :ets.insert(@table, for({ip, entry} <- bans, do: {{:ip_ban, ip}, entry}))

  defp decode(:ops, %{"uuid" => uuid, "name" => name} = entry) when is_binary(name) do
    level = if is_integer(entry["level"]), do: min(max(entry["level"], 0), 4), else: 0

    with {:ok, uuid} <- ListFile.parse_uuid(uuid),
         do: [{uuid, %{name: name, level: level, bypass: entry["bypassesPlayerLimit"] == true}}],
         else: (_ -> [])
  end

  defp decode(:whitelist, %{"uuid" => uuid, "name" => name}) when is_binary(name) do
    with {:ok, uuid} <- ListFile.parse_uuid(uuid), do: [{uuid, name}], else: (_ -> [])
  end

  defp decode(:bans, %{"uuid" => uuid, "name" => name} = entry) when is_binary(name) do
    with {:ok, uuid} <- ListFile.parse_uuid(uuid),
         do: [{uuid, ban_fields(entry)}],
         else: (_ -> [])
  end

  defp decode(:ip_bans, %{"ip" => ip} = entry) when is_binary(ip), do: [{ip, ban_fields(entry)}]
  defp decode(_kind, _entry), do: []

  defp ban_fields(entry) do
    created =
      with text when is_binary(text) <- entry["created"],
           {:ok, _} <- ListFile.parse_date(text),
           do: text,
           else: (_ -> ListFile.now_text())

    expires =
      with text when is_binary(text) <- entry["expires"],
           {:ok, _} <- ListFile.parse_date(text),
           do: text,
           else: (_ -> "forever")

    %{
      "created" => created,
      "source" => if(is_binary(entry["source"]), do: entry["source"], else: "(Unknown)"),
      "expires" => expires
    }
    |> Map.merge(Map.take(entry, ["name"]))
    |> then(fn fields ->
      if is_binary(entry["reason"]), do: Map.put(fields, "reason", entry["reason"]), else: fields
    end)
  end

  defp load_cache(%{dir: nil} = state), do: state

  defp load_cache(state) do
    case ListFile.read(file(state.dir, :cache)) do
      {:ok, entries} ->
        cache =
          for %{"uuid" => uuid, "name" => name, "expiresOn" => expires} <- entries,
              is_binary(name),
              {:ok, uuid} <- [ListFile.parse_uuid(uuid)],
              {:ok, expires} <- [ListFile.parse_date(expires)],
              into: %{},
              do:
                {String.downcase(name),
                 %{
                   uuid: uuid,
                   name: name,
                   expires: expires,
                   used: System.unique_integer([:monotonic])
                 }}

        %{state | cache: cache}

      :missing ->
        state
    end
  end

  defp save(%{dir: nil}, _kind), do: :ok

  defp save(state, kind) do
    ListFile.write(file(state.dir, kind), Enum.map(Map.fetch!(state, kind), &encode(kind, &1)))
  end

  defp encode(:ops, {uuid, op}),
    do: [
      {"uuid", ListFile.uuid_string(uuid)},
      {"name", op.name},
      {"level", op.level},
      {"bypassesPlayerLimit", op.bypass}
    ]

  defp encode(:whitelist, {uuid, name}),
    do: [{"uuid", ListFile.uuid_string(uuid)}, {"name", name}]

  defp encode(:bans, {uuid, entry}),
    do: [{"uuid", ListFile.uuid_string(uuid)}, {"name", entry["name"]}] ++ ban_list(entry)

  defp encode(:ip_bans, {ip, entry}), do: [{"ip", ip}] ++ ban_list(entry)

  defp ban_list(entry) do
    [{"created", entry["created"]}, {"source", entry["source"]}, {"expires", entry["expires"]}] ++
      if(entry["reason"], do: [{"reason", entry["reason"]}], else: [])
  end
end
