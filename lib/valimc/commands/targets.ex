defmodule Valimc.Commands.Targets do
  @moduledoc """
  Selector targets (VMC-077o): vanilla's `EntitySelector.findPlayers` over the
  published player projections, never over connections' full state.

  Candidates are slim rows read from the `Valimc.Player.PlayerList` table by a match
  specification (pid, name, uuid, entity id, address, dimension, position,
  rotation, health, game mode and progression); a selector limited to the
  source's level (`world_limited`: a distance, box or position option) takes
  only that dimension's players, and one with a bounded distance only the
  players the spatial index holds in the regions it can reach.

  Commands that act on any entity (`/kill`, `/teleport`) also select bodies
  (mobs and other entities, VMC-043a) from the sections' published views
  (`entities/2`); the rest select players.
  """
  alias Valimc.Data.Grid
  alias Valimc.Text.Error
  alias Valimc.Text.{Range, Selector}
  alias Valimc.Protocol.Registries
  alias Valimc.Commands.Source

  @fields ~w(pid name uuid entity_id address dimension x y z yaw pitch game_mode progression)a
  # A player's health: its `living` state (VMC-077k), or the loose `health` before it.
  @health [:living, :health]

  @doc "Online players as projections."
  def online, do: projections(:all)

  @doc "Online players as projections, the source's own player first."
  def online(%Source{player: nil}), do: projections(:all)

  def online(%Source{player: player}) do
    rows = projections(:all)
    own = Enum.find(rows, &(&1.pid == player.pid))
    if own, do: [own | List.delete(rows, own)], else: rows
  end

  @doc "Online players a selector picks, the source itself included (`findPlayers`)."
  def players(%Source{} = source, selector) do
    candidates =
      cond do
        not selector.world_limited -> online(source)
        reach = reach(selector, source) -> nearby(source, reach)
        true -> Enum.filter(online(source), &(&1.dimension == source.dimension))
      end

    own = source.player && Enum.find(candidates, &(&1.pid == source.player.pid))
    find(selector, candidates, own, source.position)
  end

  @doc "`EntityArgument.getPlayers`: at least one player or `argument.entity.notfound.player`."
  def required_players(source, selector) do
    case players(source, selector) do
      [] -> Error.fail!("argument.entity.notfound.player")
      players -> players
    end
  end

  @doc "`getEntities`: at least one entity (players are ValiMC's selectable entities)."
  def required_entities(source, selector) do
    case players(source, selector) do
      [] -> Error.fail!("argument.entity.notfound.entity")
      entities -> entities
    end
  end

  @doc "`getPlayer`/`getEntity`: exactly one, with vanilla's not-found errors."
  def single_player(source, selector) do
    case players(source, selector) do
      [player] -> player
      [] -> Error.fail!("argument.entity.notfound.player")
      _ -> Error.fail!("argument.player.toomany")
    end
  end

  def single_entity(source, selector) do
    case players(source, selector) do
      [entity] -> entity
      [] -> Error.fail!("argument.entity.notfound.entity")
      _ -> Error.fail!("argument.entity.toomany")
    end
  end

  @doc """
  Every entity a selector picks, players and bodies (`findEntities`). A body
  is `%{kind: :body, section, type, uuid, entity_id, dimension, x, y, z, yaw,
  pitch, alive, width, height}`.
  """
  def entities(%Source{} = source, %Selector{includes_entities: false} = selector),
    do: players(source, selector)

  def entities(%Source{} = source, selector) do
    players =
      cond do
        not selector.world_limited -> online(source)
        reach = reach(selector, source) -> nearby(source, reach)
        true -> Enum.filter(online(source), &(&1.dimension == source.dimension))
      end

    bodies = bodies(if(selector.world_limited, do: source.dimension))
    own = source.player && Enum.find(players, &(&1.pid == source.player.pid))
    find(selector, players ++ bodies, own, source.position)
  end

  @doc "`getEntities` over players and bodies: at least one, or `argument.entity.notfound.entity`."
  def required_any(source, selector) do
    case entities(source, selector) do
      [] -> Error.fail!("argument.entity.notfound.entity")
      entities -> entities
    end
  end

  @doc "`getEntity` over players and bodies: exactly one."
  def single_any(source, selector) do
    case entities(source, selector) do
      [entity] -> entity
      [] -> Error.fail!("argument.entity.notfound.entity")
      _ -> Error.fail!("argument.entity.toomany")
    end
  end

  defp bodies(dimension) do
    for {section, view} <- Valimc.World.bodies(dimension) do
      {x, y, z} = view.at
      type = Valimc.Data.EntityTypes.fetch(view.type)

      %{
        kind: :body,
        section: section,
        type: view.type,
        uuid: view.uuid,
        entity_id: view.entity_id,
        dimension: elem(section, 0),
        x: x,
        y: y,
        z: z,
        yaw: view.yaw,
        pitch: view.pitch,
        alive: view.alive,
        width: type.width,
        height: type.height
      }
    end
  end

  @doc "The online player with `uuid` as a projection, or nil."
  def by_uuid(uuid), do: Enum.find(projections(:all), &(&1.uuid == uuid))

  @doc "Whether a projection or player is alive (`Entity.isAlive`)."
  def alive?(%{kind: :body, alive: alive}), do: alive
  def alive?(%{living: %{health: %{value: value}}}), do: value > 0
  def alive?(%{health: %{value: value}}), do: value > 0
  def alive?(_player), do: true

  # Slim rows of ready players, in `pids` (`:all`: every one).
  defp projections(pids) do
    variables = Enum.with_index(@fields, &{&1, :"$#{&2 + 2}"})

    specs =
      for key <- @health do
        variables = [{key, :"$99"} | variables]
        {{:"$1", Map.new([{:ready, true} | variables])}, [], [Map.new(variables)]}
      end

    rows = :ets.select(Valimc.Player.PlayerList, specs)
    if pids == :all, do: rows, else: Enum.filter(rows, &MapSet.member?(pids, &1.pid))
  end

  # The horizontal reach of a bounded `distance` from the selector's origin.
  defp reach(%{distance: %{max: max}} = selector, source) when is_number(max) and max <= 512 do
    {x, _, z} = source.position
    {selector.x || x, selector.z || z, max}
  end

  defp reach(_selector, _source), do: nil

  # Players the spatial index holds in the regions within `radius` of `{x, z}`.
  defp nearby(source, {x, z, radius}) do
    size = Grid.region_size() * 16
    [rx0, rx1] = for edge <- [x - radius, x + radius], do: Integer.floor_div(floor(edge), size)
    [rz0, rz1] = for edge <- [z - radius, z + radius], do: Integer.floor_div(floor(edge), size)

    pids =
      for rx <- rx0..rx1,
          rz <- rz0..rz1,
          {_, pid} <-
            :ets.lookup(Valimc.SpatialIndex, {source.dimension, rx, rz}),
          into: MapSet.new(),
          do: pid

    projections(pids)
  end

  # Players a selector picks for a source at `origin` (`EntitySelector.findEntities`):
  # `players` are the online player maps, `self` the source's player map or nil.
  defp find(%Selector{} = s, players, self, origin) do
    # Players have no saved entity data to compare yet.
    if Enum.any?(s.predicates, &match?({:nbt, _, _}, &1)),
      do: Error.refuse!("Selector nbt= is not supported yet")

    cond do
      s.player_name ->
        players
        |> Enum.filter(&(String.downcase(&1[:name] || "") == String.downcase(s.player_name)))
        |> Enum.take(1)

      s.uuid ->
        players |> Enum.filter(&(&1.uuid == s.uuid)) |> Enum.take(1)

      s.current_entity ->
        if self && matches?(s, self, origin), do: [self], else: []

      true ->
        position = {s.x || elem(origin, 0), s.y || elem(origin, 1), s.z || elem(origin, 2)}

        players
        |> Enum.filter(&matches?(s, &1, position))
        |> sort(s.order, position)
        |> Enum.take(s.max_results)
    end
  end

  defp matches?(s, player, position) do
    in_box?(s, player, position) and in_distance?(s, player, position) and
      Enum.all?(s.predicates, &predicate?(&1, player))
  end

  defp in_box?(%{dx: nil, dy: nil, dz: nil}, _player, _position), do: true

  defp in_box?(s, player, {x, y, z}) do
    {x0, x1} = span(s.dx || 0.0, x)
    {y0, y1} = span(s.dy || 0.0, y)
    {z0, z1} = span(s.dz || 0.0, z)
    # The entity's hitbox (a player's 0.6 x 1.8, smaller when crouching is
    # ignored; a body's its type's) intersects the box.
    half = Map.get(player, :width, 0.6) / 2
    height = Map.get(player, :height, 1.8)

    player.x + half > x0 and player.x - half < x1 and player.y + height > y0 and
      player.y < y1 and player.z + half > z0 and player.z - half < z1
  end

  defp span(delta, origin) when delta < 0, do: {origin + delta, origin + 1.0}
  defp span(delta, origin), do: {origin, origin + delta + 1.0}

  defp in_distance?(%{distance: nil}, _player, _position), do: true

  defp in_distance?(%{distance: range}, player, {x, y, z}) do
    squared = (player.x - x) ** 2 + (player.y - y) ** 2 + (player.z - z) ** 2
    Range.matches_squared?(range, squared)
  end

  # `Entity.isAlive` (commands audit E9: comparing the health struct with 0 was always true).
  defp predicate?(:alive, player), do: alive?(player)

  defp predicate?({:name, name, inverted}, entity),
    do: Map.get(entity, :name) == name != inverted

  defp predicate?({:gamemode, mode, inverted}, player),
    do: game_mode(player) == mode != inverted

  defp predicate?({:team, team, inverted}, _player), do: team == "" != inverted
  defp predicate?({:type, type, inverted}, entity), do: type == type_of(entity) != inverted

  defp predicate?({:type_tag, tag, inverted}, entity) do
    members = Registries.tag("minecraft:entity_type", tag) || []
    Valimc.Data.EntityTypes.id(type_of(entity)) in members != inverted
  end

  defp predicate?({:tag, "", inverted}, _player), do: not inverted
  defp predicate?({:tag, _tag, inverted}, _player), do: inverted
  defp predicate?({:scores, _}, _player), do: false
  defp predicate?({:advancements, _}, _player), do: false
  defp predicate?({:predicate, _, _}, _player), do: false

  defp predicate?({:level, range}, player),
    do: Range.matches?(range, get_in(player, [:progression, :experience, :level]) || 0)

  defp predicate?({:rot_x, range}, player),
    do: Range.rotation?(range, Map.get(player, :pitch, 0.0))

  defp predicate?({:rot_y, range}, player), do: Range.rotation?(range, Map.get(player, :yaw, 0.0))

  defp type_of(%{kind: :body, type: type}), do: type
  defp type_of(_player), do: "minecraft:player"

  defp game_mode(%{game_mode: %{current: mode}}), do: mode
  defp game_mode(%{game_mode: mode}) when is_atom(mode), do: mode
  defp game_mode(_), do: nil

  defp sort(players, :arbitrary, _), do: players
  defp sort(players, :random, _), do: Enum.shuffle(players)
  defp sort(players, :nearest, position), do: Enum.sort_by(players, &squared(&1, position))

  defp sort(players, :furthest, position),
    do: Enum.sort_by(players, &squared(&1, position), :desc)

  defp squared(player, {x, y, z}),
    do: (player.x - x) ** 2 + (player.y - y) ** 2 + (player.z - z) ** 2
end
