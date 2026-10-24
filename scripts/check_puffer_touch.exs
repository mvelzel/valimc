alias Valimc.AI.{Facts, Mind, Self, World}
alias Valimc.Entity.Body
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 6, do: raise("Incomplete pufferfish contact fixtures")

for row <- cases do
  {:ok, body} = Body.new("minecraft:pufferfish")
  body = %{body | data: %{body.data | puff: row["puff"]}}
  {width, height, eye} = Body.dimensions(body)

  target = %{
    kind: :player,
    uuid: <<2::128>>,
    alive: true,
    mode: :survival,
    x: 0.0,
    y: 64.0,
    z: 0.0,
    width: 0.6,
    height: 1.8
  }

  self =
    Valimc.AI.Mobs.Pufferfish.after_ai(%Self{
      type: body.type,
      uuid: <<1::128>>,
      x: 0.0,
      y: 64.0,
      z: 0.0,
      width: width,
      height: height,
      eye: eye,
      data: body.data,
      mob: body.mob,
      mind: %Mind{},
      facts: Facts.mob(body.type),
      world: %World{players: [target]}
    })

  case self.effects do
    [] ->
      true = row["damage"] == nil and row["effects"] == [] and row["packets"] == []

    [{:hurt, {:player, _}, :mob_attack, damage, actions}] ->
      true = damage == row["damage"]

      if row["accepted"] do
        actual =
          for {:add, id, [{duration, amplifier, _, _, _}]} <- actions,
              do: [Valimc.Data.EffectTypes.name(id), duration, amplifier]

        true = actual == row["effects"]
        {_, payload} = Valimc.Protocol.Packets.puffer_sting()
        body = IO.iodata_to_binary(payload)
        true = [Base.encode16(body, case: :lower)] == row["packets"]
      else
        [] = row["effects"]
        [] = row["packets"]
      end
  end
end

IO.puts(
  "PASS: 6 native pufferfish contact attempts, admitted/refused effects and sting packet payloads"
)
