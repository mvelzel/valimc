alias Valimc.Living.{Armor, Damage, DamageSource}
alias Valimc.Menus.Inventory
alias Valimc.Data.EffectTypes
alias Valimc.Protocol.{ItemStack, ItemTypes}
# The enchantment engine reads the living facts (VMC-037q).
Valimc.Entity.MobFacts.install!()
Code.ensure_loaded!(Damage)
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for c <- cases do
  slots =
    Map.new(c["gear"], fn gear ->
      stack = %{
        ItemStack.new(
          if(gear["item_id"], do: ItemTypes.item(gear["item_id"])["name"], else: "stone")
        )
        | components: %{
            "minecraft:enchantments" => gear["direct"],
            "minecraft:stored_enchantments" => gear["stored"]
          },
          removed:
            if(gear["removed"],
              do: MapSet.new(["minecraft:attribute_modifiers"]),
              else: MapSet.new()
            )
      }

      {gear["slot"], stack}
    end)

  inventory = %Inventory{slots: slots}
  source = String.to_existing_atom(c["source"])

  effects =
    if c["resistance"] >= 0,
      do: %{EffectTypes.id("resistance") => [{-1, c["resistance"], false, true, true}]},
      else: %{}

  {:ok, damage} = Damage.protect(Armor.equipment(inventory), source, c["amount"], effects)
  matches = if c["damage"] == "infinity", do: damage > 1024, else: damage == c["damage"]

  unless Damage.protection(Armor.equipment(inventory), source) == c["protection"] and
           matches and
           DamageSource.exhaustion(source) == c["exhaustion"],
         do: raise("Native environmental protection differs #{inspect({c, damage})}")

  if Map.has_key?(c, "armored") do
    attributes = Armor.attributes(Armor.equipment(inventory))

    {:ok, armored} =
      if DamageSource.wears_armor?(source),
        do: Damage.armor_absorb(c["amount"], attributes.armor, attributes.toughness),
        else: {:ok, c["amount"]}

    unless attributes.armor == c["armor"] and attributes.toughness == c["toughness"] and
             armored == c["armored"] and
             c["wear_calls"] == if(DamageSource.wears_armor?(source), do: 1, else: 0) and
             (c["wear_calls"] == 0 or c["wear_amount"] == c["amount"]),
           do: raise("Native fire armor/selection order differs #{inspect(c)}")
  end
end

IO.puts(
  "PASS: #{length(cases)} native worn protection/armor/Resistance/magic cases and source-specific wear callbacks; finite results exact, lethal overflow bounded."
)
