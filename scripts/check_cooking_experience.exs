[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Blocks.CookingAwards

true = raw["version"] == "26.3"
true = raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"
true = raw["rates"] == 8 and length(raw["cases"]) == 712
true = length(raw["math_boundaries"]) == 219

for row <- raw["cases"] ++ raw["math_boundaries"] do
  uses = %{row["recipe"] => row["count"]}
  draws = %{row["recipe"] => row["draw"]}

  if Map.get(row, "safe", true) do
    {:ok, plan} = CookingAwards.plan(uses, draws)
    true = plan.experience == row["experience"]
    true = map_size(plan.draws_used) == row["draws"]

    true =
      plan.recipes == [
        %{recipe: row["recipe"], uses: row["count"], experience: row["experience"]}
      ]

    if row["orbs"], do: true = Enum.sum(row["orbs"]) == plan.experience
  else
    {:error, :experience_limit} = CookingAwards.plan(uses, draws)
  end
end

# An occupied processor's removal (VMC-032c5, `preRemoveSideEffects`): its
# slots drop as item entities and each stored recipe pays out at the block's
# centre, every fraction drawn as `draw`. The spill holds every slot's
# stack and the orbs are vanilla's, value for value, at the same spot.
removals = raw["removals"]
true = length(removals) == 8
alias Valimc.Protocol.{ItemStack, ItemTypes}
alias Valimc.World.{ContainerLifecycle, Containers, ContainerSpills}

for row <- removals do
  kind = String.to_existing_atom(row["kind"])
  [x, y, z] = row["origin"]
  position = {x, y, z}
  key = Valimc.Data.Grid.region_key(Valimc.Data.Grid.chunk_key(x, z))

  slots =
    row["slots"]
    |> Enum.map(fn
      nil -> nil
      [item, count] -> ItemStack.new(item, count)
    end)
    |> List.to_tuple()

  recipes = row["recipes"]
  {:ok, block} = Valimc.Blocks.CookingBlocks.placement(kind, 0.0)
  {:ok, containers, entry} = Containers.create_cooking(%Containers{}, key, position, kind)

  {:ok, containers, _} =
    Containers.replace_cooking(
      containers,
      position,
      entry.revision,
      %Valimc.Blocks.Cooking{slots: slots},
      recipes
    )

  {:ok, %{removed: removed}} =
    ContainerLifecycle.plan(containers, key, %{position => block}, %{position => 0})

  {:ok, store} = ContainerSpills.add(Valimc.Entity.Store.new(), key, removed)

  spilled =
    for {_, %{kind: :item, stack: stack}} <- store.entries,
        reduce: %{},
        do: (acc -> Map.update(acc, stack.item_id, stack.count, &(&1 + stack.count)))

  vanilla =
    Enum.reduce(row["items"], %{}, fn item, acc ->
      Map.update(acc, ItemTypes.id(item["item"]), item["count"], &(&1 + item["count"]))
    end)

  unless spilled == vanilla,
    do: raise("#{row["kind"]}: spilled #{inspect(spilled)}, vanilla #{inspect(vanilla)}")

  draws = Map.new(recipes, fn {name, _} -> {name, row["draw"]} end)
  {:ok, orbs} = ContainerSpills.cooking_orbs(position, recipes, draws)
  ours = orbs |> Enum.flat_map(&List.duplicate(&1.value, &1.count)) |> Enum.sort()
  theirs = row["orbs"] |> Enum.map(& &1["value"]) |> Enum.sort()

  unless ours == theirs,
    do: raise("#{row["kind"]}: orbs #{inspect(ours)}, vanilla #{inspect(theirs)}")

  centre = [x + 0.5, y + 0.5, z + 0.5]
  true = Enum.all?(row["orbs"], &(&1["at"] == centre))
  true = Enum.all?(orbs, &([&1.x, &1.y, &1.z] == centre))

  true =
    row["draws"] ==
      Enum.count(recipes, fn {name, n} ->
        {:ok, xp} = Valimc.Blocks.CookingRecipes.experience(name)
        product = Valimc.Data.Float32.round(Valimc.Data.Float32.round(n) * xp)
        product != Float.floor(product)
      end)
end

IO.puts(
  "PASS: #{length(removals)} occupied furnace, smoker and blast furnace removals spill every slot and pay out vanilla's orbs at the block's centre"
)

IO.puts(
  "PASS: #{length(raw["cases"])} actual cooking award hooks across 8 stock XP rates and #{length(raw["math_boundaries"])} native float32/Mth boundaries; exact amounts, strict rounding and RNG-use counts. No live award admission."
)
