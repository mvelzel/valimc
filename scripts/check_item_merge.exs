alias Valimc.{ItemMotionState, Physics.ItemMerge, Protocol.ItemStack}
[path] = System.argv()
data = :json.decode(File.read!(path))

decode = fn hex ->
  {:ok, stack} = ItemStack.decode(Base.decode16!(hex, case: :lower))
  stack
end

input = fn row ->
  %{
    stack: decode.(row["stack"]),
    motion: %ItemMotionState{age: row["age"], pickup_delay: row["delay"]},
    alive: row["alive"],
    target: row["target"]
  }
end

for {row, n} <- Enum.with_index(data["pairs"]) do
  a = input.(row["a"])
  b = input.(row["b"])

  unless ItemMerge.eligible?(a) == row["a_eligible"] and
           ItemMerge.eligible?(b) == row["b_eligible"],
         do: raise("eligibility #{n}")

  case {row["allowed"], ItemMerge.pair(a, b)} do
    {false, {:error, :not_mergeable}} ->
      :ok

    {true, {:ok, plan}} ->
      unless Atom.to_string(plan.recipient) == row["recipient"] and
               ItemStack.same_item?(plan.stack, decode.(row["stack"])) and
               plan.stack.count == decode.(row["stack"]).count and
               plan.donor_stack == decode.(row["donor_stack"]) and plan.motion.age == row["age"] and
               plan.motion.pickup_delay == row["delay"] and
               plan.donor_stack == nil == row["donor_removed"],
             do: raise("pair #{n}: #{inspect(plan)} expected #{inspect(row)}")

    other ->
      raise("pair #{n}: #{inspect(other)} expected #{inspect(row)}")
  end
end

for {row, n} <- Enum.with_index(data["proximity"]) do
  unless ItemMerge.near?({0, 0, 0}, List.to_tuple(row["b"])) == row["near"],
    do: raise("proximity #{n}: #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(data["pairs"])} native pair decisions and #{length(data["proximity"])} AABB boundaries."
)
