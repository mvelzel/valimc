alias Valimc.Native
alias Valimc.Physics.Kernel
[file] = System.argv()
data = file |> File.read!() |> JSON.decode!()
shapes = data["shapes"] |> Enum.map(&Kernel.shape/1) |> List.to_tuple()
floats = fn values -> values |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

for c <- data["cases"] do
  position = floats.(c["position"])
  colliders = Enum.map(c["shapes"], &{elem(shapes, &1), nil, position})
  result = Native.physics_parity_move(colliders, floats.(c["box"]), floats.(c["requested"]))
  bits = for value <- Tuple.to_list(result), do: Base.encode16(<<value::float-64>>, case: :lower)

  if bits != c["result_bits"],
    do: raise("Native movement differs: #{inspect(c)} actual #{inspect(result)}")
end

IO.puts(
  "PASS: #{length(data["cases"])} native movement vectors through the kernel (all three exact result components)."
)
