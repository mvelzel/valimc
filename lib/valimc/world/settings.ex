defmodule Valimc.World.Settings do
  @moduledoc """
  The world's small durable settings (VMC-077a), kept in its `settings.json`:
  the world spawn (vanilla's `RespawnData`: dimension, block, yaw and pitch),
  the default game mode (`/defaultgamemode`), the admin switches
  `white-list` (`/whitelist on|off`) and `player-idle-timeout`
  (`/setidletimeout`), which vanilla keeps in `server.properties`, and the
  game rules `/gamerule` changed that the clock does not hold
  (`Valimc.World.GameRules`).

  One owner serialises changes. It writes the whole file crash-safely
  (`Valimc.Storage.DurableFile`) and only then publishes the new values in
  `:persistent_term`, so a reader never sees a value the disk does not hold
  and a failed write changes nothing. Values never set come from the
  configuration. A file that does not read stops the start, as does the
  `admin-settings.json` of worlds from before VMC-077a (not migrated, VMC-077 D4).
  """
  use GenServer

  @key {__MODULE__, :values}
  @file_name "settings.json"
  @modes ~w(survival creative adventure spectator)a

  @doc "The defaults: the configuration's values and a spawn at (0, 64, 0) in the overworld."
  def defaults do
    %{
      spawn: %{dimension: :overworld, position: {0, 64, 0}, yaw: 0.0, pitch: 0.0},
      default_game_mode: Valimc.config(:default_game_mode),
      white_list: Valimc.config(:white_list) == true,
      idle_timeout: Valimc.config(:player_idle_timeout),
      game_rules: %{}
    }
  end

  @doc "A published value (`defaults/0` before the owner started)."
  def get(key), do: Map.fetch!(:persistent_term.get(@key, nil) || defaults(), key)

  @doc """
  Change `changes` (a keyword list of keys of `defaults/0`): `:ok`, `:unchanged`
  when every value already was so, or `{:error, reason}` when the file could
  not be written (nothing changes).
  """
  def put(server \\ __MODULE__, changes), do: GenServer.call(server, {:put, Map.new(changes)})

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :publish, name == __MODULE__), name: name)
  end

  @doc "The values saved in the world at `base` (unset keys absent), or why they do not read."
  def read(nil), do: {:ok, %{}}

  def read(base) do
    old = Path.join(base, "admin-settings.json")
    path = Path.join(base, @file_name)

    cond do
      File.exists?(old) ->
        {:error,
         {:settings_format_too_old,
          "#{old} is from before VMC-077a; remove it and set its switches again"}}

      true ->
        case File.read(path) do
          {:ok, text} ->
            with {:ok, json} when is_map(json) <- JSON.decode(text),
                 {:ok, values} <- decode(json) do
              {:ok, values}
            else
              _ -> {:error, {:invalid_settings, path}}
            end

          {:error, :enoent} ->
            {:ok, %{}}

          {:error, reason} ->
            {:error, {:settings_unreadable, path, reason}}
        end
    end
  end

  @doc "Write `values` as the world at `base`'s saved settings (creation, import, the owner)."
  def write(nil, _values), do: :ok

  def write(base, values),
    do: Valimc.Storage.DurableFile.write(Path.join(base, @file_name), encode(values))

  @impl true
  def init(opts) do
    base = Keyword.get(opts, :dir, Valimc.config(:world_path))

    case read(base) do
      {:ok, saved} ->
        state = %{base: base, saved: saved, publish: Keyword.fetch!(opts, :publish)}
        publish(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:settings_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:put, changes}, _from, state) do
    true = Enum.all?(changes, fn {key, value} -> valid?(key, value) end)
    saved = Map.merge(state.saved, changes)

    cond do
      Map.merge(defaults(), state.saved) == Map.merge(defaults(), saved) ->
        {:reply, :unchanged, state}

      true ->
        case write(state.base, saved) do
          :ok ->
            state = %{state | saved: saved}
            publish(state)
            {:reply, :ok, state}

          {:error, _} = error ->
            {:reply, error, state}
        end
    end
  end

  defp publish(%{publish: false}), do: :ok
  defp publish(state), do: :persistent_term.put(@key, Map.merge(defaults(), state.saved))

  defp valid?(:spawn, %{dimension: dimension, position: {x, y, z}, yaw: yaw, pitch: pitch}),
    do:
      dimension in Valimc.World.Dimension.ids() and is_integer(x) and is_integer(y) and
        is_integer(z) and
        is_float(yaw) and is_float(pitch)

  defp valid?(:default_game_mode, mode), do: mode in @modes
  defp valid?(:white_list, on), do: is_boolean(on)
  defp valid?(:idle_timeout, minutes), do: is_integer(minutes) and minutes >= 0

  defp valid?(:game_rules, rules),
    do: is_map(rules) and Enum.all?(rules, fn {rule, value} -> valid_rule?(rule, value) end)

  defp valid?(_key, _value), do: false

  defp encode(values) do
    values
    |> Enum.map(fn
      {:spawn, spawn} ->
        {x, y, z} = spawn.position

        {"spawn",
         %{
           "dimension" => Valimc.World.Dimension.name(spawn.dimension),
           "pos" => [x, y, z],
           "yaw" => spawn.yaw,
           "pitch" => spawn.pitch
         }}

      {:default_game_mode, mode} ->
        {"default_game_mode", Atom.to_string(mode)}

      {:white_list, on} ->
        {"white_list", on}

      {:idle_timeout, minutes} ->
        {"player_idle_timeout", minutes}

      {:game_rules, rules} ->
        {"game_rules", Map.new(rules, fn {rule, value} -> {Atom.to_string(rule), value} end)}
    end)
    |> Map.new()
    |> JSON.encode!()
  end

  defp decode(json) do
    Enum.reduce_while(json, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case decode(key, value) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode("spawn", %{"dimension" => name, "pos" => [x, y, z], "yaw" => yaw, "pitch" => pitch})
       when is_integer(x) and is_integer(y) and is_integer(z) and is_number(yaw) and
              is_number(pitch) do
    with {:ok, dimension} <- Valimc.World.Dimension.parse(name),
         do:
           {:ok, :spawn,
            %{dimension: dimension, position: {x, y, z}, yaw: yaw * 1.0, pitch: pitch * 1.0}}
  end

  defp decode("default_game_mode", mode) when is_binary(mode) do
    case Enum.find(@modes, &(Atom.to_string(&1) == mode)) do
      nil -> :error
      mode -> {:ok, :default_game_mode, mode}
    end
  end

  defp decode("white_list", on) when is_boolean(on), do: {:ok, :white_list, on}

  defp decode("player_idle_timeout", minutes) when is_integer(minutes) and minutes >= 0,
    do: {:ok, :idle_timeout, minutes}

  defp decode("game_rules", rules) when is_map(rules) do
    known = Map.new(Valimc.World.GameRules.names(), &{Atom.to_string(&1), &1})

    decoded =
      for {name, value} <- rules, rule = known[name], valid_rule?(rule, value), do: {rule, value}

    if length(decoded) == map_size(rules), do: {:ok, :game_rules, Map.new(decoded)}, else: :error
  end

  defp decode(_key, _value), do: :error

  # A rule keeps its default's type.
  defp valid_rule?(rule, value) do
    case Valimc.World.GameRules.default(rule) do
      default when is_boolean(default) -> is_boolean(value)
      default when is_integer(default) -> is_integer(value)
      _ -> false
    end
  end
end
