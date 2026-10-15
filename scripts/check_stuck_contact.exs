alias Valimc.Physics.{BlockCollisions.Frame, CollisionContext, StuckContact}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
poses = %{"standing" => :standing, "crouching" => :crouching, "swimming" => :swimming}

for c <- cases do
  states = Map.new(c["blocks"], fn [x, y, z, id] -> {{x, y, z}, id} end)

  facts = %StuckContact{
    pose: poses[c["pose"]],
    feet: List.to_tuple(c["to"]),
    flying: c["flying"],
    spectator: c["spectator"],
    weaving: c["weaving"]
  }

  context =
    CollisionContext.entity(Enum.at(c["to"], 1))
    |> CollisionContext.with_entity(c["fall"], false, false)

  result =
    StuckContact.sample(
      %Frame{states: states, fences: %{}, entities: %{}},
      List.to_tuple(c["from"]),
      List.to_tuple(c["to"]),
      context,
      facts
    )

  actual =
    case result do
      {:ok, value} -> value
      error -> raise("Native stuck contact failed #{inspect(c)} #{inspect(error)}")
    end

  multiplier = if actual.multiplier, do: Tuple.to_list(actual.multiplier), else: :null
  position = if actual.last, do: Tuple.to_list(actual.last.position), else: :null
  state = if actual.last, do: actual.last.state, else: -1
  fall = if actual.reset_fall, do: 0.0, else: c["fall"]

  unless multiplier == c["multiplier"] and position == c["last_position"] and
           state == c["last_state"] and fall == c["fall_after"],
         do: raise("Native slowing scene mismatch #{inspect(c)} #{inspect(actual)}")
end

IO.puts("PASS: #{length(cases)} actual native ordered slowing contact scenes.")
