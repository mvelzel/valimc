defmodule Valimc.Command.Targets do
  @moduledoc """
  Selector targets (VMC-077o): vanilla's `EntitySelector.findPlayers` over the
  published player projections, never over connections' full state.

  Candidates are slim rows read from the `Valimc.Players` table by a match
  specification (pid, name, uuid, entity id, address, dimension, position,
  rotation, health, game mode and progression); a selector limited to the
  source's level (`world_limited`: a distance, box or position option) takes
  only that dimension's players, and one with a bounded distance only the
  players the spatial index holds in the regions it can reach. Players are
  ValiMC's only selectable entities until mobs have owners.
  """
  alias Valimc.Command.{Error, Selector, Source}

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
    Selector.find(selector, candidates, own, source.position)
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

  @doc "The online player with `uuid` as a projection, or nil."
  def by_uuid(uuid), do: Enum.find(projections(:all), &(&1.uuid == uuid))

  @doc "Whether a projection or player is alive (`Entity.isAlive`)."
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

    rows = :ets.select(Valimc.Players, specs)
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
    size = Valimc.config(:region_size) * 16
    [rx0, rx1] = for edge <- [x - radius, x + radius], do: Integer.floor_div(floor(edge), size)
    [rz0, rz1] = for edge <- [z - radius, z + radius], do: Integer.floor_div(floor(edge), size)

    pids =
      for rx <- rx0..rx1,
          rz <- rz0..rz1,
          {_, pid} <-
            :ets.lookup(Valimc.SpatialIndex, Valimc.Dimension.scope(source.dimension, {rx, rz})),
          into: MapSet.new(),
          do: pid

    projections(pids)
  end
end
