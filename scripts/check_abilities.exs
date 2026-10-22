alias Valimc.Player.Abilities
alias Valimc.Protocol.Packets
import Bitwise
[path] = System.argv()
native = path |> File.read!() |> JSON.decode!()

modes = %{
  "survival" => :survival,
  "creative" => :creative,
  "adventure" => :adventure,
  "spectator" => :spectator
}

for c <- native["transitions"] do
  flags = c["initial"]

  initial = %Abilities{
    invulnerable: (flags &&& 1) != 0,
    flying: (flags &&& 2) != 0,
    may_fly: (flags &&& 4) != 0,
    infinite_materials: (flags &&& 8) != 0,
    may_build: false,
    flying_speed: 0.2,
    walking_speed: 0.3
  }

  result = Abilities.for_mode(Map.fetch!(modes, c["mode"]), initial)
  {_, bytes} = Packets.abilities(result)

  if bytes != Base.decode16!(c["payload"], case: :lower) or result.may_build != c["build"],
    do: raise("Native ability mismatch: #{inspect(c)}")
end

for c <- native["requests"], permission <- [false, true] do
  initial = %Abilities{flying: true, may_fly: permission}
  {:ok, result} = Abilities.request_flight(initial, <<c["flags"]>>)

  if result.flying != (c["flying"] and permission) or
       c["canonical"] != if(c["flying"], do: 2, else: 0),
     do: raise("Native flight request mismatch: #{inspect(c)}")
end

IO.puts(
  "PASS: native mode/ability bytes, speed preservation and all 512 permission-gated flight requests."
)
