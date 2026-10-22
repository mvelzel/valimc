alias Valimc.Native
alias Valimc.Physics.{CollisionContext, Kernel}
Valimc.Data.BlockFacts.install!()
[file] = System.argv()
native = file |> File.read!() |> JSON.decode!()
axes = %{"x" => 0, "y" => 1, "z" => 2}
floats = fn values -> values |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end
empty = Kernel.context(CollisionContext.empty())

for c <- native["queries"] do
  colliders =
    Enum.zip_with(c["shapes"], c["offsets"], fn id, offset ->
      {shape, block_offset} = Native.physics_parity_shape(id, {0, 0, 0}, empty)
      {shape, block_offset, floats.(offset)}
    end)

  result =
    Native.physics_parity_clip(
      colliders,
      Map.fetch!(axes, c["axis"]),
      floats.(c["box"]),
      c["delta"] * 1.0,
      c["raw"]
    )

  bits = Base.encode16(<<result::float-64>>, case: :lower)

  if bits != c["result_bits"],
    do: raise("Native clipping differs: #{inspect(c)}; kernel #{inspect(result)} #{bits}")
end

for c <- native["intersections"] do
  if Valimc.Data.Box.intersects?(floats.(c["a"]), floats.(c["b"])) != c["intersects"],
    do: raise("Native box intersection differs")
end

IO.puts(
  "PASS: #{length(native["queries"])} bit-exact native clipping results through the kernel and #{length(native["intersections"])} box intersections."
)
