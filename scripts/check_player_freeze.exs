alias Valimc.PlayerEnvironment
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()

Enum.each(cases, fn c ->
  expected = PlayerEnvironment.freeze_effect(c["initial"], c["allowed"])

  if expected != c["frozen"] or c["inside"] != true,
    do: raise("Native freeze effect differs: #{inspect(c)}")
end)

IO.puts(
  "PASS: #{length(cases)} native freeze effects/accessors; cooling is referenced separately to LivingEntity.aiStep."
)
