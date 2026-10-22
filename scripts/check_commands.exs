# Parses CommandTreeOracle's inputs with ValiMC's dispatcher and writes ValiMC's
# commands packets per permission level for Mojang's decoder (VMC-053).
#
#   mix run --no-start scripts/check_commands.exs CASES.json OUT_DIR RESULTS.json
alias Valimc.Commands.Parser.Dispatcher
alias Valimc.Text.{Error, Reader}
alias Valimc.Commands.Source
alias Valimc.Text
alias Valimc.Protocol.Wire

[cases_path, out_dir, results_path] = System.argv()
File.mkdir_p!(out_dir)

for level <- [0, 4] do
  hex = Base.encode16(Valimc.Commands.graph_payload(level), case: :lower)
  File.write!(Path.join(out_dir, "graph-#{level}.hex"), hex)
end

# One suggestion reply for Mojang's packet decoder.
{_id, body} =
  Valimc.Commands.Suggestions.packet(
    7,
    Valimc.Commands.Suggestions.suggest("/time set n", Source.parse_only(4))
  )

File.write!(
  Path.join(out_dir, "suggestions.hex"),
  Base.encode16(IO.iodata_to_binary(body), case: :lower)
)

cases = :json.decode(File.read!(cases_path))

results =
  for %{"level" => level, "input" => input} <- cases do
    command = String.replace_prefix(input, "/", "")
    source = Source.parse_only(level)
    parse = Dispatcher.parse(Valimc.Commands.root(), command, source)

    outcome =
      case Dispatcher.finish(parse) do
        {:ok, last, context} ->
          reader = Reader.new(command)

          arguments =
            Map.new(last.arguments, fn {name, {_value, {from, to}}} ->
              {name, Reader.slice(reader, from, to)}
            end)

          %{"path" => Dispatcher.path(context), "arguments" => arguments}

        {:error, error} ->
          messages =
            for component <- Error.feedback(error, command),
                do:
                  component
                  |> Text.encode()
                  |> Wire.text_component()
                  |> IO.iodata_to_binary()
                  |> Base.encode16(case: :lower)

          %{"messages" => messages}
      end

    Map.merge(%{"level" => level, "input" => input}, outcome)
  end

File.write!(results_path, :json.encode(results))

IO.puts(
  "PASS: ValiMC parsed #{length(results)} command inputs and encoded graphs for levels 0 and 4."
)
