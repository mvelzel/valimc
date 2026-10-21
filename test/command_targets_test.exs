defmodule Valimc.CommandTargetsTest do
  @moduledoc """
  Selector targets over the published player projections (VMC-077o): `@e`
  skips dead players (commands audit E9) and a world-limited selector stays in
  the source's dimension (E10).
  """
  # Writes rows into the global player table.
  use ExUnit.Case, async: false
  alias Valimc.Command.{Reader, Selector, Source, Targets}

  setup do
    rows =
      for {name, dimension, x, health} <- [
            {"Alive", :overworld, 0.5, 20.0},
            {"Nether", :the_nether, 1.5, 20.0},
            {"Dead", :overworld, 2.5, 0.0}
          ] do
        pid = spawn(fn -> Process.sleep(:infinity) end)

        player = %{
          pid: pid,
          ready: true,
          name: name,
          uuid: :crypto.strong_rand_bytes(16),
          entity_id: System.unique_integer([:positive]),
          address: nil,
          dimension: dimension,
          x: x,
          y: 64.0,
          z: 0.5,
          yaw: 0.0,
          pitch: 0.0,
          health: %Valimc.PlayerHealth{value: health},
          game_mode: %Valimc.GameMode{current: :survival},
          progression: %Valimc.PlayerProgression{}
        }

        :ets.insert(Valimc.Players, {pid, player})
        region = Valimc.World.region_key(Valimc.World.chunk_key(x, 0.5))
        :ets.insert(Valimc.SpatialIndex, {Valimc.Dimension.scope(dimension, region), pid})
        pid
      end

    on_exit(fn ->
      for pid <- rows do
        :ets.delete(Valimc.Players, pid)
        :ets.match_delete(Valimc.SpatialIndex, {:_, pid})
      end
    end)

    :ok
  end

  defp names(selector, dimension) do
    {parsed, _} = Selector.parse(Reader.new(selector), true)
    source = %{Source.console() | dimension: dimension, position: {0.5, 64.0, 0.5}}

    Targets.players(source, parsed)
    |> Enum.map(& &1.name)
    |> Enum.filter(&(&1 in ~w(Alive Nether Dead)))
    |> Enum.sort()
  end

  test "@e and @n select only living players; @a selects the dead too" do
    assert names("@e", :overworld) == ~w(Alive Nether)
    assert names("@a", :overworld) == ~w(Alive Dead Nether)
  end

  test "a world-limited selector stays in the source's dimension" do
    assert names("@a[distance=..10]", :overworld) == ~w(Alive Dead)
    assert names("@a[distance=..10]", :the_nether) == ~w(Nether)
    assert names("@a[x=0,y=64,z=0,dx=5,dy=5,dz=5]", :overworld) == ~w(Alive Dead)
  end
end
