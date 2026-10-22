defmodule Valimc.StorageLogIndexTest do
  # A load reads only its owner's frames, where the stripe's index says they
  # are (VMC-077t); an owner with none costs a lookup.
  use ExUnit.Case, async: true
  alias Valimc.Storage.Log

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-log-index-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  defp commit(base, route, frames) do
    Log.commit_group(base, route, frames, self())
    for {owner, seq, _} <- frames, do: assert_receive({:storage_durable, ^owner, ^seq}, 10_000)
  end

  test "frames are read from the index: another owner's damaged frame does not matter", ctx do
    route = {:region, :overworld, {91_000, 7}}
    a = {:region, :overworld, {91_000, 7}}
    b = {:region, :overworld, {91_001, 7}}
    c = {:region, :overworld, {91_002, 7}}

    commit(ctx.base, route, [{a, 1, "a1"}, {a, 2, "a2"}])
    commit(ctx.base, route, [{b, 1, :binary.copy("b", 100_000)}])
    commit(ctx.base, route, [{c, 1, "c1"}, {a, 3, "a3"}])

    # Damage the middle of b's frame, which a scan of the segment would refuse.
    [segment] = Path.wildcard(Path.join(Log.dir(ctx.base, Log.stripe(route)), "log.*"))
    {:ok, bytes} = File.read(segment)
    {at, _} = :binary.match(bytes, :binary.copy("b", 1_000))

    File.write!(
      segment,
      binary_part(bytes, 0, at) <> "X" <> binary_part(bytes, at + 1, byte_size(bytes) - at - 1)
    )

    assert Log.frames(ctx.base, a, 0) == [{1, "a1"}, {2, "a2"}, {3, "a3"}]
    assert Log.frames(ctx.base, a, 2) == [{3, "a3"}]
    assert Log.frames(ctx.base, c, 0) == [{1, "c1"}]
    # Never written: no stripe holds it.
    assert Log.frames(ctx.base, {:region, :overworld, {91_003, 7}}, 0) == []
    # Covered: the stripe answers from its index without reading.
    Log.covered(ctx.base, a, 3)
    assert Log.frames(ctx.base, a, 0) == []
  end

  test "a restarted stripe indexes its frames again", ctx do
    route = {:region, :overworld, {91_100, 7}}
    a = {:region, :overworld, {91_100, 7}}
    commit(ctx.base, route, [{a, 1, "a1"}])
    commit(ctx.base, route, [{a, 2, "a2"}])

    [{pid, _}] = Registry.lookup(Valimc.StorageRegistry, {ctx.base, Log.stripe(route)})
    Valimc.TestScope.kill(pid)

    assert Log.frames(ctx.base, a, 0) == [{1, "a1"}, {2, "a2"}]
  end
end
