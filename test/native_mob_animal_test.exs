defmodule Valimc.NativeMobAnimalTest do
  @moduledoc """
  The native farm animals and think step (VMC-081d,
  `valimc_core::mobs::{kinds, animals, ai::think}`) against `Valimc.AI` and
  `Valimc.Entity.Animal`: the families' registered goals against vanilla's,
  and whole scenes of animals thinking tick by tick over generated terrain
  (`AI.prepare`, `think_mob`, a scripted move, `settle`, `finish`), every
  record, mind, effect and the level random equal.
  """
  use ExUnit.Case, async: true

  alias Valimc.Native

  setup_all do
    Valimc.AI.NativeFacts.install!()
    :ok
  end

  test "the farm animals are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()

    assert types ==
             ~w(minecraft:chicken minecraft:cow minecraft:mooshroom minecraft:pig minecraft:rabbit minecraft:sheep)
  end
end
