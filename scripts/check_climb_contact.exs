alias Valimc.World.View
alias Valimc.Native
alias Valimc.Physics.{BlockScan, Kernel}
alias Valimc.Data.PlayerPose
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
{:ok, geometry} = PlayerPose.geometry(:standing, {0.5, 64.0, 0.5})
{:ok, plan} = BlockScan.plan(geometry.box)
states = Map.new(plan, fn {p, _} -> {p, 0} end)

for c <- cases do
  frame = View.of(Map.merge(states, %{{0, 64, 0} => c["state"], {0, 63, 0} => c["below"]}))

  {:ok, {climbing, _scaffolding}} =
    Native.physics_player_parity(
      :climb_contact,
      {Kernel.native(frame, nil), {0, 64, 0}, c["flying"], c["spectator"], c["gliding"]}
    )

  if climbing != c["climbing"],
    do: raise("Native climb contact mismatch #{inspect(c)} #{inspect(climbing)}")

  for p <- c["queries"] do
    unless Map.has_key?(states, List.to_tuple(p)),
      do: raise("Native climb dependency outside frame #{inspect(p)}")
  end
end

IO.puts("PASS: #{length(cases)} native climb contacts and bounded frame dependencies.")
