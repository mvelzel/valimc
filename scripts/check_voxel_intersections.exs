alias Valimc.Native
alias Valimc.Physics.Kernel
[file] = System.argv()
data = file |> File.read!() |> JSON.decode!()
shapes = data["shapes"] |> Enum.map(&Kernel.shape/1) |> List.to_tuple()
floats = fn values -> values |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

for c <- data["boxes"] do
  actual = Native.physics_parity_box_shape(floats.(c["bounds"]))
  if actual != elem(shapes, c["shape"]), do: raise("Native world box differs: #{inspect(c)}")
end

for [left, right, expected] <- data["pairs"] do
  actual = Native.physics_parity_intersects(elem(shapes, left), elem(shapes, right))

  if actual != expected,
    do:
      raise(
        "Native intersection differs: #{left}/#{right}, expected #{expected}, actual #{actual}"
      )
end

IO.puts(
  "PASS: #{length(data["pairs"])} native intersections / #{length(data["boxes"])} world boxes through the kernel."
)
