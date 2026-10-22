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

IO.puts(
  "PASS: #{length(raw["cases"])} actual cooking award hooks across 8 stock XP rates and #{length(raw["math_boundaries"])} native float32/Mth boundaries; exact amounts, strict rounding and RNG-use counts. No live award admission."
)
