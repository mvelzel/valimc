# Support checks (VMC-029c) run for every neighbour of every committed edit. Cost
# of the check per neighbour: plain states (the common case) and dependent states
# in random neighbourhoods.
#   mix run --no-start bench/block_support.exs
alias Valimc.Block.Support
alias Valimc.Registry.Blocks

:rand.seed(:exsss, {29, 29, 29})
count = Blocks.state_count()
dependent = Enum.filter(0..(count - 1), &Support.dependent?/1)
plain = Enum.reject(0..(count - 1), &Support.dependent?/1)

neighbourhood = fn ->
  Map.new(
    for dx <- -1..1, dy <- -1..1, dz <- -1..1, do: {{dx, 64 + dy, dz}, :rand.uniform(count) - 1}
  )
end

case_of = fn states ->
  for _ <- 1..10_000 do
    {Enum.random(states), [:rand.uniform(6) - 1], neighbourhood.()}
  end
end

inputs = %{"plain states" => case_of.(plain), "dependent states" => case_of.(dependent)}

Benchee.run(
  %{
    "Support.update" => fn cases ->
      for {state, directions, cells} <- cases,
          do: Support.update({0, 64, 0}, state, directions, &Map.get(cells, &1, 0))
    end
  },
  inputs: inputs,
  time: 3,
  warmup: 1,
  print: [configuration: false]
)
