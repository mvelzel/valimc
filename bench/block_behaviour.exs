# Owned block-entity check (VMC-068): the two generated lookups callers used to
# chain versus one class-keyed behaviour dispatch.
#   mix run --no-start bench/block_behaviour.exs
alias Valimc.CookingBlocks
alias Valimc.Registry.Blocks

:rand.seed(:exsss, {68, 68, 68})
chests = Enum.to_list(Blocks.states("chest"))
furnaces = Enum.to_list(Blocks.states("furnace"))

inputs = %{
  "random states" => Enum.map(1..10_000, fn _ -> :rand.uniform(Blocks.state_count()) - 1 end),
  "chests and furnaces" =>
    Enum.map(1..10_000, fn i -> Enum.at(chests ++ furnaces, rem(i, 32)) end)
}

old = fn state -> Valimc.ChestAccess.single?(state) or CookingBlocks.kind(state) != nil end
new = fn state -> Valimc.Block.block_entity(state) != nil end

for {_, states} <- inputs, do: true = Enum.map(states, old) == Enum.map(states, new)

Benchee.run(
  %{
    "single? or kind" => fn states -> Enum.each(states, old) end,
    "Block.block_entity" => fn states -> Enum.each(states, new) end
  },
  inputs: inputs,
  time: 3,
  warmup: 1,
  print: [configuration: false]
)
