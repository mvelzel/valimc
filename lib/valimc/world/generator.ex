defmodule Valimc.World.Generator do
  @moduledoc """
  A world's terrain generator (VMC-024d), recorded in its `world.json`: flat
  terrain for worlds without a generator entry (and imports), or vanilla's
  overworld terrain for a seed (`"generator": {"type": "vanilla", "seed": …}`).

  New worlds take the configured generator (`:generator`, `VALIMC_GENERATOR`,
  flat by default) and seed (`:seed`, `VALIMC_SEED`, random otherwise). A new
  vanilla world's spawn is vanilla's spawn search over its generated chunks
  (`Valimc.World.SpawnSearch`, VMC-027d).

  Regions of a vanilla world generate the chunks their log has no column image
  for when they load (`columns/2`), and persist them before serving them, so a
  chunk is generated once.
  """
  alias Valimc.{Native, Worldgen}
  alias Valimc.Protocol.Data
  alias Valimc.World.Spawn

  @settings "minecraft:overworld"
  @biome_source "minecraft:overworld"
  # A batch is one native call of about 0.1 s; a region runs up to four at once.
  @batch 16
  @batches 4

  @doc """
  Create the configured world's metadata when it has none and remember its
  generator; call at start, before `Spawn.load!/0`.
  """
  def init! do
    base = Valimc.config(:world_path)

    with base when is_binary(base) <- base,
         false <- File.exists?(Spawn.path(base)),
         :vanilla <- Valimc.config(:generator) do
      seed = Valimc.config(:seed) || random_seed()
      :ok = create(base, seed)
    end

    :persistent_term.put({__MODULE__, :world}, of(base))
  end

  @doc "The configured world's generator (`init!/0`)."
  def current, do: :persistent_term.get({__MODULE__, :world}, :flat)

  @doc """
  What the client learns about a generator in its spawn information: the hashed
  seed (`BiomeManager.obfuscateSeed`: the first eight bytes of the SHA-256 of
  the seed, both little-endian; 0 for flat terrain) and whether the world is
  flat.
  """
  def client_info(:flat), do: {0, true}

  def client_info({:vanilla, seed}) do
    <<hashed::little-signed-64, _::binary>> = :crypto.hash(:sha256, <<seed::little-signed-64>>)
    {hashed, false}
  end

  @doc "Write `world.json` for a new vanilla world at `base` with `seed` and vanilla's world spawn."
  def create(base, seed) when is_integer(seed) do
    {x, y, z} = Valimc.World.SpawnSearch.world_spawn({:vanilla, seed})
    File.mkdir_p!(base)

    File.write(
      Spawn.path(base),
      JSON.encode!(%{
        "spawn" => [x, y, z],
        "yaw" => 0.0,
        "generator" => %{"type" => "vanilla", "seed" => seed}
      })
    )
  end

  @doc "The generator of the world at `base`: `:flat` or `{:vanilla, seed}`."
  def of(nil), do: :flat

  def of(base) do
    with {:ok, text} <- File.read(Spawn.path(base)),
         {:ok, %{"generator" => %{"type" => "vanilla", "seed" => seed}}} when is_integer(seed) <-
           JSON.decode(text) do
      {:vanilla, seed}
    else
      _ -> :flat
    end
  end

  @doc """
  Column images (`chunk => image`) of generated `chunks` of a vanilla world, in
  batches of #{@batch} generated at once on the seed's pool of states (VMC-071).
  """
  def columns({:vanilla, seed}, chunks) do
    chunks
    |> Enum.chunk_every(@batch)
    |> Task.async_stream(&generate(seed, &1),
      max_concurrency: @batches,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, generated}, acc ->
      Enum.reduce(generated, acc, fn {cx, cz, image, _heights}, acc ->
        Map.put(acc, {cx, cz}, image)
      end)
    end)
  end

  @doc "The spawn target's origin column `{x, z}` of `seed`, or nil (VMC-027d)."
  def spawn_origin(seed) do
    checked_out(seed, fn state ->
      {:ok, origin} = Native.worldgen_spawn_origin(state)
      origin
    end)
  end

  defp generate(seed, chunks) do
    checked_out(seed, fn state ->
      {:ok, generated} =
        Native.worldgen_columns(state, @biome_source, protocol_biomes(), chunks)

      generated
    end)
  end

  # A worldgen state compiles its samplers once and keeps bounded pure caches
  # behind its own lock, so one state serialises every caller. Each seed has one
  # state per dirty CPU scheduler; a call checks a free one out and waits briefly
  # while all are busy. Any state gives the same chunks.
  defp checked_out(seed, fun) do
    {states, busy} = pool(seed)
    slot = take(busy, tuple_size(states), :erlang.phash2(self(), tuple_size(states)), 0)

    try do
      fun.(elem(states, slot))
    after
      :atomics.put(busy, slot + 1, 0)
    end
  end

  defp take(busy, size, start, tried) do
    slot = rem(start + tried, size)

    cond do
      :atomics.compare_exchange(busy, slot + 1, 0, 1) == :ok ->
        slot

      tried + 1 < size ->
        take(busy, size, start, tried + 1)

      true ->
        Process.sleep(2)
        take(busy, size, start, 0)
    end
  end

  defp pool(seed) do
    case :persistent_term.get({__MODULE__, seed}, nil) do
      nil ->
        size = :erlang.system_info(:dirty_cpu_schedulers_online)

        states =
          List.to_tuple(
            for _ <- 1..size do
              {:ok, state} = Worldgen.new(seed, @settings)
              state
            end
          )

        pool = {states, :atomics.new(size, signed: false)}
        :persistent_term.put({__MODULE__, seed}, pool)
        pool

      pool ->
        pool
    end
  end

  defp protocol_biomes do
    case :persistent_term.get({__MODULE__, :biomes}, nil) do
      nil ->
        ids =
          Enum.map(Worldgen.biome_names(), &Data.registry_id("minecraft:worldgen/biome", &1))

        :persistent_term.put({__MODULE__, :biomes}, ids)
        ids

      ids ->
        ids
    end
  end

  defp random_seed do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    seed
  end
end
