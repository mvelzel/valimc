alias Valimc.Entity.{Body, MobFacts, Store}
alias Valimc.Native
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 6, do: raise("Incomplete pufferfish contact fixtures")
MobFacts.install!()

for row <- cases do
  {:ok, body} = Body.new("minecraft:pufferfish")
  body = %{body | data: %{body.data | puff: row["puff"]}}
  section = Native.mob_section_oracle_new()

  {:ok, _} =
    Native.mob_section_insert(
      section,
      [{1, Store.body_record(body, <<1::128>>, {0.0, 64.0, 0.0})}],
      false
    )

  target = %{uuid: <<2::128>>, mode: :survival, position: {0.0, 64.0, 0.0}}

  # `Pufferfish.aiStep` after its super: the players it touches.
  {_, _, _, effects, _, _} =
    Native.mob_oracle_body_turn(section, 1, :after_ai, %{players: [target]})

  case effects do
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
