alias Valimc.Entity.ItemMotionState
alias Valimc.{Protocol.ItemStack, Entity.Store}
[path] = System.argv()
rows = :json.decode(File.read!(path))

for row <- rows do
  record = %{
    uuid: <<1::128>>,
    x: 0.5,
    y: row["y"],
    z: 0.5,
    stack: ItemStack.new("stone"),
    motion: %ItemMotionState{age: -32768, pickup_delay: 32767, no_gravity: true}
  }

  {:ok, items} = Store.restore({0, 0}, [record])
  {_, expired} = Store.age(items, 1, row["minimum"])

  unless expired != [] == row["removed"] and
           (not row["removed"] or row["reason"] == "DISCARDED"),
         do: raise("item void boundary differs: #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(rows)} native item-discard boundaries with unlimited-age/no-gravity fixtures."
)
