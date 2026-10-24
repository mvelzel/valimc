alias Valimc.AI.Random
alias Valimc.Entity.{Body, Bucketable}
alias Valimc.Protocol.ItemStack

[path, inventory_path, positions_path, spawn_path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 606, do: raise("Incomplete native bucket cases")

decode = fn hex, input ->
  case hex |> Base.decode16!(case: :lower) |> ItemStack.decode() do
    {:ok, stack} -> stack
    error -> raise("Native bucket decode #{inspect(input)}: #{inspect(error)}")
  end
end

same = fn actual, expected, label ->
  if ItemStack.identity_key(actual) != ItemStack.identity_key(expected),
    do: raise("#{label}: #{inspect(actual)} != #{inspect(expected)}")

  # A real wire round trip must retain every saved component.
  {:ok, ^actual} = actual |> ItemStack.encode() |> IO.iodata_to_binary() |> ItemStack.decode()
end

for row <- cases do
  input = row["input"]
  {:ok, body} = Body.new(input["type"])

  data =
    case input["type"] do
      "minecraft:salmon" ->
        %{body.data | size: input["variant"]}

      "minecraft:tropical_fish" ->
        %{body.data | variant: input["packed"]}

      "minecraft:axolotl" ->
        %{
          body.data
          | variant: input["variant"],
            age:
              if(input["profile"] == 1,
                do: -1200,
                else: if(input["profile"] == 2, do: 6000, else: 0)
              ),
            age_locked: input["profile"] == 1
        }

      _ ->
        body.data
    end

  special = input["profile"] == 1
  data = if input["profile"] == 2, do: Map.put(data, :from_bucket, true), else: data
  data = if special and input["type"] == "minecraft:pufferfish", do: %{data | puff: 2}, else: data
  health = %{body.mob.living.health | value: input["health"] * 1.0}

  mob = %{
    body.mob
    | no_ai: special,
      persistent: special,
      living: %{body.mob.living | health: health}
  }

  mob =
    if special and input["type"] == "minecraft:axolotl",
      do: %{mob | ai: %{random: Random.new(7), memories: %{has_hunting_cooldown: {true, 1234}}}},
      else: mob

  body = %{
    body
    | data: data,
      mob: mob,
      no_gravity: special,
      custom_name: if(special, do: {:string, "Bucket friend"})
  }

  captured = Bucketable.capture(body)
  {:ok, data} = row["data"] |> Base.decode16!(case: :lower) |> Valimc.Data.NBT.decode()
  {:ok, restored_item} = Valimc.Protocol.ItemData.stack(data)
  same.(captured, restored_item, "native saved bucket item")

  true =
    Valimc.Data.NBT.identity_key(Valimc.Protocol.ItemData.tag(captured)) ==
      Valimc.Data.NBT.identity_key(data)

  same.(captured, decode.(row["captured"], input), "capture #{inspect(input)}")
  {:ok, released} = Bucketable.release(captured)

  same.(
    Bucketable.capture(released),
    decode.(row["released"], input),
    "release #{inspect(input)}"
  )

  true = released.data.from_bucket == row["from_bucket"]
  true = released.mob.persistent == row["persistent"]
  if input["type"] == "minecraft:pufferfish", do: true = released.data.puff == row["puff"]

  {:ok, _, %{discard: true, hand: {:capture, ^captured}}} =
    Bucketable.interact(body, %{item: ItemStack.new("water_bucket")})

  :pass = Bucketable.interact(body, %{item: ItemStack.new("bucket")})
  true = row["water"] and not row["empty"]
end

IO.puts(
  "PASS: #{length(cases)} native fish/axolotl bucket capture, release and component round trips"
)

alias Valimc.Menus.Inventory

slot = fn
  n when n < 9 -> 36 + n
  n when n < 36 -> n
  40 -> 45
  n -> 44 - n
end

for row <- JSON.decode!(File.read!(inventory_path)) do
  before =
    for [n, hex] <- row["before"],
        stack = decode.(hex, row),
        stack != nil,
        into: %{},
        do: {slot.(n), stack}

  expected =
    for [n, hex] <- row["after"],
        stack = decode.(hex, row),
        stack != nil,
        into: %{},
        do: {slot.(n), stack}

  inventory = %Inventory{slots: before, infinite_materials: row["creative"]}
  hand = if row["off"], do: :off, else: :main
  stack = decode.(row["captured"], row)

  {next, left} =
    Valimc.Player.Buckets.captured(inventory, hand, Inventory.held(inventory, hand), stack)

  true = next.slots == expected
  true = if(left, do: [left], else: []) == Enum.map(row["drops"], &decode.(&1, row))
end

Valimc.Data.BlockFacts.install!()

for row <- JSON.decode!(File.read!(positions_path)) do
  read = fn cell -> if cell == {0, 64, 0}, do: row["state"], else: 0 end
  {:ok, {0.5, y, 0.5}} = Bucketable.spawn_point(row["type"], {0, 64, 0}, read)
  if y != 64 + row["offset"], do: raise("Bucket release position #{inspect(row)}: #{y}")
end

IO.puts(
  "PASS: native creative/survival capture inventory/overflow and constructor-sized release collision"
)

for row <- JSON.decode!(File.read!(spawn_path)) do
  stack = decode.(row["bucket"], row)
  world = %Valimc.AI.World{random: Random.new(row["seed"]), difficulty: :normal}
  {:ok, body, world} = Bucketable.spawn(stack, <<7::128>>, {0.5, 64.0, 0.5}, world)
  <<yaw::signed-32>> = <<body.yaw::float-32>>

  if yaw != row["yaw"] or world.random != row["level_after"],
    do: raise("Bucket spawn random/yaw #{inspect(row)}: #{inspect({yaw, world.random})}")

  same.(Bucketable.capture(body), decode.(row["recaptured"], row), "finalized bucket spawn")
end

IO.puts("PASS: 60 native bucket spawn yaw, level random and saved-data ordering cases")
