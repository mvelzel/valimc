alias Valimc.Native
alias Valimc.Physics.{BlockScan, CollisionContext, Kernel}
alias Valimc.Data.Box
[path] = System.argv()
data = path |> File.read!() |> :json.decode()
bits = fn t -> for n <- Tuple.to_list(t), do: <<n::float-64>> end
vec = fn l -> l |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

Enum.each(data["jumps"], fn c ->
  {:ok, result} =
    Native.physics_player_parity(
      :jump,
      {vec.(c["initial"]), c["factor"] * 1.0, c["sprint"], c["yaw"] * 1.0, c["amplifier"]}
    )

  if bits.(result) != bits.(List.to_tuple(c["velocity"])),
    do: raise("Jump mismatch #{inspect(c)} #{inspect(result)}")
end)

Enum.each(data["air"], fn c ->
  {_, y, _} = initial = vec.(c["initial"])

  air = %{
    on_ground: c["ground"],
    friction: c["friction"] * 1.0,
    friction_modifier: 1.0,
    air_drag_modifier: 1.0,
    gravity: 0.08,
    levitation: nil,
    discard_friction: false,
    omnidirectional: false
  }

  {:ok, result} = Native.physics_player_parity(:air, {initial, y * 1.0, air, c["flying"]})

  if bits.(result) != bits.(List.to_tuple(c["velocity"])),
    do: raise("Player travel mismatch #{inspect(c)} #{inspect(result)}")
end)

Enum.each(data["normalization"], fn c ->
  {:ok, actual} = Native.physics_player_parity(:normalize, vec.(c["initial"]))

  if bits.(actual) != bits.(List.to_tuple(c["velocity"])),
    do: raise("Native dead zone mismatch #{inspect(c)}")
end)

Enum.each(data["support"], fn c ->
  box = vec.(c["box"])
  {x, y, z} = List.to_tuple(c["position"])
  supplied = Map.new(c["states"], &{List.to_tuple(&1["position"]), &1["state"]})
  {:ok, plan} = BlockScan.plan(Box.expand_towards(box, {0.0, -0.51, 0.0}))

  groups =
    Enum.group_by(plan, fn {{px, _, pz}, _} ->
      Valimc.World.region_key(Valimc.World.chunk_key(px, pz))
    end)

  observations =
    Enum.flat_map(groups, fn {key, values} ->
      owner =
        {spawn(fn ->
           receive do
             :stop -> :ok
           end
         end), make_ref()}

      Enum.chunk_every(values, 128)
      |> Enum.map(fn chunk ->
        %{
          owner: owner,
          region: key,
          revision: 1,
          blocks: Map.new(chunk, fn {p, _} -> {p, Map.get(supplied, p, 0)} end)
        }
      end)
    end)

  frame = Valimc.World.View.of(Map.new(Enum.flat_map(observations, &Map.to_list(&1.blocks))))

  context =
    CollisionContext.entity(y, false) |> CollisionContext.with_entity(0.0, false, false)

  {:ok, {support, below, landing}} =
    Native.physics_player_parity(
      :material,
      {Kernel.native(frame, box), box, {x * 1.0, y * 1.0, z * 1.0}, Kernel.context(context)}
    )

  for pid <- observations |> Enum.map(&elem(&1.owner, 0)) |> Enum.uniq(), do: send(pid, :stop)
  support = if support, do: Tuple.to_list(support)

  if support != c["support"] or Tuple.to_list(below) != c["below"],
    do: raise("Native support mismatch #{inspect(c)} #{inspect(below)} #{inspect(support)}")

  unless Tuple.to_list(landing) == c["landing"],
    do: raise("Native landing material position differs #{inspect({c, landing})}")
end)

IO.puts(
  "PASS: #{length(data["jumps"])} native jumps, #{length(data["air"])} player travel branches, #{length(data["normalization"])} dead zones and #{length(data["support"])} supporting-block selections."
)
