defmodule Valimc.PhantomSpawnerTest do
  @moduledoc """
  The phantom spawner's countdown (VMC-043b6): it waits one to two minutes
  between visits, tries only in the overworld, and spawns nothing while the
  sky is bright.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.JavaRandom
  alias Valimc.World.PhantomSpawner

  defp group(dimension, countdown, darken) do
    %{
      dimension: dimension,
      spawning: %{phantoms: countdown},
      environment: %{difficulty: 2, darken: darken, sea_level: 63},
      rest: [{0.5, 70.0, 0.5, false, 500_000}],
      sections: %{}
    }
  end

  test "it counts down, then waits one to two minutes; never outside the overworld" do
    random = JavaRandom.new(7)
    assert {4, ^random, []} = PhantomSpawner.tick(group(:overworld, 5, 0), random)

    {countdown, _random, made} = PhantomSpawner.tick(group(:overworld, 1, 0), random)
    assert countdown in 1200..2380 and made == []

    assert {0, ^random, []} = PhantomSpawner.tick(group(:the_nether, 0, 11), random)
  end
end
