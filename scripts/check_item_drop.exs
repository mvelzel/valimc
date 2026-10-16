alias Valimc.Physics.ItemDrop
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()
unless length(cases) == 720, do: raise("Incomplete native item launch observations")

errors =
  Enum.map(cases, fn row ->
    pose = %{x: 10.5, y: 80.0, z: 10.5, yaw: row["yaw"], pitch: row["pitch"]}
    kind = if row["scatter"], do: :scattered, else: :directed
    {:ok, actual} = ItemDrop.launch(pose, row["eye"], kind, row["random"])

    [x, y, z] = Tuple.to_list(actual.velocity)
    [native_x, native_y, native_z] = row["velocity"]
    error = max(abs(x - native_x), abs(z - native_z))
    # Java and Erlang libm may round horizontal random jitter differently.
    unless Tuple.to_list(actual.position) == row["position"] and y == native_y and
             error <= 1.0e-15 and
             actual.pickup_delay == row["pickup_delay"],
           do: raise("Native item launch differs #{inspect({row, actual}, limit: :infinity)}")

    error
  end)

IO.puts(
  "PASS:720 actual native directed/scattered launches; exact origin/vertical velocity/pickup delay, horizontal error <=1e-15 (observed #{Enum.max(errors)})."
)
