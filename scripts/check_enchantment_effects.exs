# VMC-037q: every `EnchantmentEffectOracle` case through the enchantment engine
# (`Valimc.Living.Enchant`, `valimc_core::mobs::living::enchant`).
alias Valimc.Data.EntityTypes
alias Valimc.Living.Enchant
alias Valimc.Native
alias Valimc.Protocol.{DamageTypes, ItemTypes}
import Bitwise

Valimc.Entity.MobFacts.install!()
[path] = System.argv()
cases = :json.decode(File.read!(path))

entity = fn
  :null ->
    nil

  nil ->
    nil

  view ->
    Enchant.entity(
      type_id: EntityTypes.id(view["type"]),
      on_ground: view["on_ground"],
      in_water: view["in_water"],
      fall_distance: view["fall_distance"] * 1.0,
      tick_count: view["tick_count"]
    )
end

levels = fn list -> Enum.map(list || [], fn [name, level] -> {name, level} end) end
# `LegacyRandomSource(seed)`'s state.
state = fn seed -> bxor(seed, 0x5DEECE66D) &&& (1 <<< 48) - 1 end

f32 = fn v ->
  <<r::float-32>> = <<v::float-32>>
  r
end

normalize = fn [a, id, amount, op] -> [a, id, f32.(amount * 1.0), op] end

took_form = fn
  {:ignite, seconds} -> ["ignite", floor(f32.(seconds) * 20)]
  {:mob_effect, name, ticks, amplifier} -> ["mob_effect", name, ticks, amplifier]
  {:damage, amount, type} -> ["damage", amount, type]
  _ -> nil
end

normalize_took = fn
  ["damage", amount, type] -> ["damage", f32.(amount * 1.0), type]
  other -> other
end

context = fn c ->
  Enchant.context(
    this: entity.(c["this"]),
    attacker: entity.(c["attacker"]),
    direct: entity.(c["direct"]),
    damage:
      case c["damage"] do
        ["minecraft:" <> type, direct] -> {DamageTypes.id(String.to_atom(type)), direct}
        _ -> nil
      end
  )
end

# `doPostAttackEffectsWithItemSource`: the chestplate's effects (enchanted
# victim), then the weapon's (enchanted attacker), from one random.
post_attack = fn c ->
  ctx = context.(c)

  {:ok, {worn, random}} =
    Native.enchant_post_attack("victim", levels.(c["armour"]), "chest", ctx, state.(c["seed"]))

  {:ok, {held, _}} =
    Native.enchant_post_attack("attacker", levels.(c["weapon"]), "mainhand", ctx, random)

  actions = worn ++ held

  took = fn party ->
    for {^party, action} <- actions, action = took_form.(action), action != nil, do: action
  end

  armour =
    Enum.sum(for {_, {:item_damage, n}} <- worn, do: n)

  [took.(:victim), took.(:attacker), armour]
end

# How each hook's caller narrows the engine's float (`intValue`, `max`).
narrow = %{
  "item_damage" => &trunc/1,
  "block_experience" => &trunc/1,
  "repair_with_xp" => &max(0, trunc(&1)),
  "ammo_use" => &trunc/1,
  "projectile_piercing" => &max(0, trunc(&1)),
  "projectile_count" => &max(0, trunc(&1)),
  "projectile_spread" => &max(0.0, &1),
  "trident_return_acceleration" => &max(0, trunc(&1)),
  "fishing_luck_bonus" => &max(0, trunc(&1)),
  "fishing_time_reduction" => &max(0.0, &1),
  "crossbow_charge_time" => &max(0.0, &1)
}

failures =
  Enum.flat_map(cases, fn c ->
    hook = c["hook"]
    enchantments = levels.(c["enchantments"])

    got =
      case hook do
        "post_attack" ->
          post_attack.(c)

        "modifiers" ->
          for {a, id, amount, op} <- Enchant.modifiers(enchantments, String.to_atom(c["slot"])),
              do: [a, id, amount, op]

        h when h in ["crossbow_charge_time", "trident_spin_attack_strength"] ->
          narrow
          |> Map.get(h, & &1)
          |> then(& &1.(Enchant.unconditioned(String.to_atom(h), enchantments, c["input"])))

        _ ->
          ctx =
            Enchant.context(
              this: entity.(c["this"]),
              attacker: entity.(c["attacker"]),
              direct: entity.(c["direct"]),
              damage:
                case c["damage"] do
                  ["minecraft:" <> type, direct] -> {DamageTypes.id(String.to_atom(type)), direct}
                  _ -> nil
                end,
              tool: if(is_binary(c["tool"]), do: ItemTypes.id(c["tool"]))
            )

          case hook do
            "immune" ->
              {:ok, immune} = Native.enchant_immune(enchantments, ctx)
              if immune, do: 1.0, else: 0.0

            "equipment_drops" ->
              {:ok, {chance, _}} =
                Native.enchant_equipment_drops(
                  "attacker",
                  enchantments,
                  ctx,
                  state.(c["seed"]),
                  c["input"] * 1.0
                )

              chance

            _ ->
              {:ok, {value, _}} =
                Native.enchant_value(hook, enchantments, ctx, state.(c["seed"]), c["input"] * 1.0)

              Map.get(narrow, hook, & &1).(value)
          end
      end

    expected =
      case hook do
        "post_attack" -> [c["victim_took"], c["attacker_took"], c["armour_damage"]]
        "modifiers" -> c["modifiers"]
        _ -> c["output"]
      end

    same =
      case {got, expected} do
        {[v, a, d], [ev, ea, ed]} when hook == "post_attack" ->
          took = fn list -> Enum.map(list, &normalize_took.(&1)) end
          took.(v) == took.(ev) and took.(a) == took.(ea) and d == ed

        {g, e} when is_number(g) and is_number(e) ->
          f32.(g * 1.0) == f32.(e * 1.0)

        {g, e} when is_list(g) ->
          Enum.map(g, normalize) == Enum.map(e, normalize)

        _ ->
          false
      end

    if same, do: [], else: [{c, got}]
  end)

case failures do
  [] ->
    acting =
      Enum.count(
        cases,
        &(&1["hook"] == "post_attack" and &1["victim_took"] ++ &1["attacker_took"] != [])
      )

    IO.puts("PASS: #{length(cases)} enchantment effect cases (#{acting} post-attack cases act)")

  _ ->
    for {c, got} <- Enum.take(failures, 15),
        do: IO.puts("FAIL: #{inspect(c)} got #{inspect(got)}")

    raise "#{length(failures)} of #{length(cases)} enchantment effect cases differ"
end
