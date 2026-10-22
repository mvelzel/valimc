alias Valimc.Living.Health
alias Valimc.Player.GameMode
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

f32 = fn n ->
  <<value::float-32>> = <<n::float-32>>
  value
end

for c <- cases["health"] do
  maximum = f32.(c["maximum"])
  {:ok, health} = Health.set(%Health{maximum: maximum, value: 0.0}, c["input"])
  unless health.value == c["health"], do: raise("Native health clamp mismatch #{inspect(c)}")
  {:ok, saved} = Health.saved(%{health | hurt_ticks: 7, death_ticks: 11, cooldown: 17})

  unless saved == %{
           value: c["saved"]["Health"],
           hurt_ticks: c["saved"]["HurtTime"],
           death_ticks: c["saved"]["DeathTime"]
         },
         do: raise("Native health save mismatch #{inspect(c)}")

  for {key, value} <- [{"loaded", saved}, {"missing", nil}] do
    {:ok, loaded} = Health.restore(value, c["maximum"])

    actual = %{
      value: loaded.value,
      hurt_ticks: loaded.hurt_ticks,
      death_ticks: loaded.death_ticks,
      cooldown: loaded.cooldown
    }

    expected = %{
      value: c[key]["health"],
      hurt_ticks: c[key]["hurt"],
      death_ticks: c[key]["death"],
      cooldown: c[key]["cooldown"]
    }

    unless actual == expected and loaded.last_hurt == 0.0,
      do: raise("Native health restore mismatch #{inspect({c, key, actual})}")
  end
end

for c <- cases["windows"] do
  state = %Health{
    value: c["health"],
    cooldown: c["cooldown"],
    last_hurt: c["last"],
    hurt_ticks: 7
  }

  {:ok, result} = Health.hurt_window(state, c["amount"], c["bypass"])

  unless result.accepted == c["accepted"] and result.damage == c["damage"] and
           result.state.cooldown == c["next_cooldown"] and
           result.state.hurt_ticks == c["next_hurt"] and
           result.state.last_hurt == c["next_last"],
         do: raise("Native hurt window mismatch #{inspect({c, result})}")
end

for c <- cases["mode_windows"] do
  mode = GameMode.new(String.to_existing_atom(c["mode"]))
  immune = GameMode.abilities(mode, false).invulnerable and not c["bypass_abilities"]

  state = %Health{
    value: c["health"],
    cooldown: c["cooldown"],
    last_hurt: 2.0,
    hurt_ticks: 7
  }

  {:ok, result} = Health.hurt_window(state, 4.0)
  accepted = not immune and result.accepted
  damage = if accepted, do: result.damage, else: 0.0

  unless accepted == c["accepted"] and damage == c["damage"],
    do: raise("Native player ability/window mismatch #{inspect({c, accepted, damage})}")
end

IO.puts(
  "PASS: #{length(cases["health"])} native health saves/defaults, #{length(cases["windows"])} cooldown prefixes and #{length(cases["mode_windows"])} player ability/window prefixes."
)
