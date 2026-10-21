defmodule Valimc.WorldPresetsTest do
  @moduledoc """
  World presets live (VMC-028b): large biomes, amplified, single biome and flat
  worlds generate from their settings; presets ValiMC cannot generate are
  refused. Vanilla parity is stages `worldgen_live` (decoration over each noise
  preset) and `world_settings` (a flat chunk vanilla generates).
  """
  use ExUnit.Case, async: true
  alias Valimc.{TestScope, World}
  alias Valimc.World.{GenSettings, Generator}

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-presets-#{nonce}")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base, nonce: nonce}
  end

  defp owner!(key, attempts \\ 600) do
    case World.owner(key) do
      {:ok, owner} ->
        {:ok, owner}

      {:error, _} when attempts > 0 ->
        Process.sleep(100)
        owner!(key, attempts - 1)
    end
  end

  test "presets ValiMC cannot generate are refused; the structures flag reaches the generator",
       ctx do
    # VMC-025f5: the structures flag reaches the proto owners.
    assert {:ok, %{structures: false}} =
             Generator.spec_of(GenSettings.create("minecraft:normal", nil, 3, false))

    # Debug worlds and flat worlds with features or lakes are not generated yet.
    for {level_type, flat} <- [
          {"minecraft:debug_all_block_states", nil},
          {"minecraft:flat", ~s({"layers":[{"block":"stone","height":1}],"lakes":true})}
        ] do
      assert {:error, _} = Generator.spec_of(GenSettings.create(level_type, flat, 3, true))

      assert {:error, _} =
               Generator.create(Path.join(ctx.base, "refused"), 3,
                 level_type: level_type,
                 generator_settings: flat
               )
    end
  end

  test "a flat world's region holds its layers and biome", ctx do
    key = {9_000 + rem(ctx.nonce, 3_333) * 3, 4_100}

    flat =
      ~s({"layers":[{"block":"bedrock","height":1},{"block":"clay","height":2},{"block":"moss_block","height":1}],"biome":"minecraft:swamp"})

    :ok = Generator.create(ctx.base, 77, level_type: "minecraft:flat", generator_settings: flat)
    spec = World.Spec.fetch(ctx.base)
    assert World.Spec.client_info(spec, :overworld) |> elem(1)
    refute World.Spec.decorated?(spec, :overworld)
    # The spawn search finds the moss surface: one above the fourth layer.
    assert {:ok, %{spawn: %{position: {0, -60, 0}}}} = World.Settings.read(ctx.base)

    TestScope.isolate(key, world_path: ctx.base, region_ticks: :manual)

    on_exit(fn ->
      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(reg, key),
          do: TestScope.kill(pid)
    end)

    {:ok, _} = owner!(key)
    {rx, rz} = key
    {x, z} = {rx * 128 + 37, rz * 128 + 90}
    block = &Valimc.Registry.Blocks.default_state/1
    assert World.get_block({x, -64, z}) == block.("bedrock")
    assert World.get_block({x, -63, z}) == block.("clay")
    assert World.get_block({x, -62, z}) == block.("clay")
    assert World.get_block({x, -61, z}) == block.("moss_block")
    assert World.get_block({x, -60, z}) == block.("air")
  end
end
