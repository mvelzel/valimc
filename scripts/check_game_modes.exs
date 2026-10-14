alias Valimc.{GameMode, Protocol.Data, Protocol.Packets}
[input, output] = System.argv()
Data.load!()
native = input |> File.read!() |> JSON.decode!()

results =
  for c <- native["logins"] do
    mode = %GameMode{
      current: GameMode.from_id(c["current"]),
      previous: if(c["previous"] == -1, do: nil, else: GameMode.from_id(c["previous"]))
    }

    player = %{entity_id: 42, uuid: <<12::128>>, name: "ModeProbe", game_mode: mode}
    {_, login} = Packets.login(player)
    {_, info} = Packets.player_info(player)
    login = login |> IO.iodata_to_binary() |> Base.encode16(case: :lower)
    if login != c["login"], do: raise("Native login-mode bytes differ: #{inspect(c)}")
    Map.put(c, "info", info |> IO.iodata_to_binary() |> Base.encode16(case: :lower))
  end

for c <- native["requests"],
    do:
      if(GameMode.id(GameMode.from_id(c["id"])) != c["mode"],
        do: raise("Native request enum mismatch")
      )

File.write!(output, JSON.encode!(results))
IO.puts("PASS: Elixir mode login bytes and request lookup match native cases.")
