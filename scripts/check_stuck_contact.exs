alias Valimc.Native
alias Valimc.World.View
alias Valimc.Physics.{CollisionContext, Kernel}
alias Valimc.Data.PlayerPose
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
poses = %{"standing" => :standing, "crouching" => :crouching, "swimming" => :swimming}
vec = fn l -> l |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

for c <- cases do
  states = Map.new(c["blocks"], fn [x, y, z, id] -> {{x, y, z}, id} end)

  feet = Map.get(c, "feet", c["to"])

  body = {PlayerPose.id(poses[c["pose"]]), vec.(feet), c["flying"], c["spectator"], c["weaving"]}

  context =
    CollisionContext.entity(Enum.at(feet, 1))
    |> CollisionContext.with_entity(c["fall"], false, false)

  frame = View.of(states)

  paths =
    if Map.has_key?(c, "paths") do
      Enum.map(c["paths"], fn path ->
        {vec.(path["from"]), vec.(path["to"]),
         if(path["axis"] == :null, do: nil, else: vec.(path["axis"]))}
      end)
    else
      [{vec.(c["from"]), vec.(c["to"]), nil}]
    end

  actual =
    case Native.physics_player_parity(
           :slowing,
           {Kernel.native(frame, nil), paths, Kernel.context(context), body}
         ) do
      {:ok, {multiplier, last}} -> %{multiplier: multiplier, last: last}
      error -> raise("Native stuck contact failed #{inspect(c)} #{inspect(error)}")
    end

  multiplier = if actual.multiplier, do: Tuple.to_list(actual.multiplier), else: :null
  position = if actual.last, do: Tuple.to_list(elem(actual.last, 0)), else: :null
  state = if actual.last, do: elem(actual.last, 1), else: -1
  fall = if actual.last, do: 0.0, else: c["fall"]

  unless multiplier == c["multiplier"] and position == c["last_position"] and
           state == c["last_state"] and fall == c["fall_after"],
         do: raise("Native slowing scene mismatch #{inspect(c)} #{inspect(actual)}")
end

IO.puts("PASS: #{length(cases)} actual native ordered slowing contact scenes.")
