alias Valimc.AI.Mobs.Shulker
alias Valimc.Data.{Blocks, Box}
alias Valimc.Physics.Kernel
[path] = System.argv()
rows = JSON.decode!(File.read!(path))
unless length(rows) == 5376, do: raise("Incomplete native lid push fixtures")

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

point = fn list -> list |> Enum.map(double) |> List.to_tuple() end

float = fn n ->
  <<v::float-32>> = <<n::signed-32>>
  v
end

air = for x <- -6..6, y <- 57..71, z <- -6..6, into: %{}, do: {{x, y, z}, 0}
stone = Blocks.default_state("stone")

for row <- rows do
  at = point.(row["at"])
  start = point.(row["start"])
  {x, y, z} = start
  half = row["width"] / 2.0
  height = row["height"]
  box = {x - half, y, z - half, x + half, y + height, z + half}
  opening = Shulker.opening(row["face"], float.(row["old"]), float.(row["new"]), at)
  type = row["kind"]
  velocity = point.(row["before_velocity"])

  input =
    {start, {half, height}, velocity, {true, row["step"], row["simulates"], false},
     {0.0, false,
      type not in [
        "item",
        "orb",
        "arrow",
        "area_effect_cloud",
        "end_crystal",
        "tnt",
        "falling_block",
        "shulker_bullet"
      ], 0.08, 0.98}}

  actual =
    with {area, delta} <- opening,
         true <- type not in ["spectator", "shulker"] and not row["no_physics"],
         true <- Box.intersects?(area, box) do
      states =
        Enum.reduce(row["blocks"], air, fn [a, b, c], acc -> Map.put(acc, {a, b, c}, stone) end)

      {:ok, result} =
        Kernel.displace(
          Valimc.World.View.of(states),
          input,
          delta,
          [],
          nil,
          type not in ["player", "spectator"]
        )

      result
    else
      _ -> {start, velocity, true}
    end

  expected = {point.(row["position"]), point.(row["velocity"]), row["ground"]}

  unless actual == expected,
    do:
      raise(
        "Lid #{row["face"]} #{row["old"]}->#{row["new"]} #{type} #{inspect(start)} blocks #{inspect(row["blocks"])}: #{inspect(actual)} != native #{inspect(expected)}"
      )

  unless point.(row["shell"]) == at, do: raise("Native shulker anchor moved")

  if row["kind"] in ["husk", "no_ai", "slime", "spider"] and actual != {start, velocity, true} do
    {:ok, body} =
      Valimc.Entity.Body.new("minecraft:" <> if(type == "no_ai", do: "husk", else: type))

    body = %{body | velocity: velocity, on_ground: true}
    body = put_in(body.mob.no_ai, type == "no_ai")
    input = Valimc.Entity.MobMotion.kernel(body.type, start, body)
    {_, _, eye} = input.size
    input = %{input | size: {row["width"], height, eye}}

    states =
      Enum.reduce(row["blocks"], air, fn [a, b, c], acc -> Map.put(acc, {a, b, c}, stone) end)

    {:ok, shell} = Valimc.Entity.Body.new("minecraft:shulker")

    shell = %{
      shell
      | data: %{shell.data | attach_face: row["face"], peek_amount: float.(row["new"])}
    }

    shell_input = Valimc.Entity.MobMotion.kernel(shell.type, at, shell)

    ticker =
      Kernel.mobs_begin(Valimc.World.View.of(states), [input, shell_input], [], nil, [
        {1, Shulker.collider(shell, at)}
      ])

    {_, delta} = opening
    {:ok, result} = Kernel.mob_displace(ticker, 0, input, delta)

    unless result == expected,
      do:
        raise("Interleaved mob displacement differs: #{inspect(result)} != #{inspect(expected)}")

    unless hd(Kernel.mobs_finish(ticker)) == elem(result, 1),
      do: raise("External motion lost at tick end")
  end
end

IO.puts(
  "PASS: 5376 native opening/closing lid selections and exact external moves, six faces, mobs/NoAI/items/orbs/players and exclusions, free space and blocks"
)
