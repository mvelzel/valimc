alias Valimc.Menus.Inventory
alias Valimc.Protocol.ItemStack
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for c <- cases["vanishing"] do
  component = if c["stored"], do: "minecraft:stored_enchantments", else: "minecraft:enchantments"
  stack = %{ItemStack.new("stone") | components: %{component => %{c["name"] => c["level"]}}}
  slot = if c["slot"] == 0, do: 36, else: 8
  {:ok, inventory, drops, destroyed} = Inventory.death(%Inventory{slots: %{slot => stack}})

  unless inventory.slots == %{} and destroyed == [stack] == c["vanished"] and
           drops == if(c["vanished"], do: [], else: [stack]),
         do: raise("Native death item mismatch #{inspect(c)}")
end

slots =
  Map.new(cases["drop_order"], fn slot ->
    {slot,
     %{
       ItemStack.new("stone")
       | components: %{"minecraft:custom_data" => {:compound, %{"slot" => {:int, slot}}}}
     }}
  end)

{:ok, empty, drops, []} = Inventory.death(%Inventory{slots: slots})

order =
  Enum.map(drops, fn stack ->
    {:compound, %{"slot" => {:int, slot}}} = stack.components["minecraft:custom_data"]
    slot
  end)

unless empty.slots == %{} and order == cases["drop_order"],
  do: raise("Native inventory drop order differs")

IO.puts(
  "PASS: #{length(cases["vanishing"])} native vanishing decisions and #{length(order)} ordered inventory/equipment drops."
)
