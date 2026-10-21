# Clause-level call graph of the compiled app and the functions each script calls, for
# `check_vanilla.py --changed` (VMC-076d), from the expanded code in each module's debug
# info. Per function clause: its line range, the shape (atom tag or variable) of each
# parameter, the functions it calls with the shape of each argument, the modules it names
# as values, and the messages it sends (`GenServer.call/cast`, `send`,
# `Process.send_after`) with the shapes of message and server. The selector follows tags
# from senders to callback clauses, so a region owner's `handle_call` does not make
# every client reach every message.
# Usage: mix run --no-start scripts/call_graph.exs OUT.json SCRIPT...
defmodule CallGraph do
  # {module, function, index of the message argument, callback kind}
  @sends %{
    {GenServer, :call} => {1, "call"},
    {GenServer, :cast} => {1, "cast"},
    {:gen_server, :call} => {1, "call"},
    {:gen_server, :cast} => {1, "cast"},
    {:gen_server, :send_request} => {1, "call"},
    {:erlang, :send} => {1, "info"},
    {Process, :send} => {1, "info"},
    {Process, :send_after} => {1, "info"},
    {:erlang, :send_after} => {2, "info"}
  }

  @doc "The tag (`t:atom`) or variable (`v:name`) of a pattern or argument, else empty."
  def shape(atom) when is_atom(atom) and atom not in [nil, true, false], do: "t:#{atom}"
  def shape({atom, _}) when is_atom(atom) and atom not in [nil, true, false], do: "t:#{atom}"
  def shape({:{}, _, [atom | _]}) when is_atom(atom), do: "t:#{atom}"

  def shape({:=, _, [left, right]}),
    do: if(shape(left) != "", do: shape(left), else: shape(right))

  def shape({name, meta, context}) when is_atom(name) and is_list(meta) and is_atom(context),
    do: "v:#{name}"

  def shape(_), do: ""

  def walk(ast, known, module, locals),
    do: walk(ast, known, module, locals, %{calls: [], refs: [], sends: [], last: 0})

  defp walk({{:., _, [target, fun]}, meta, args}, known, module, locals, acc)
       when is_atom(target) and is_atom(fun) and is_list(args) do
    acc = line(acc, meta)

    case @sends[{target, fun}] do
      {index, kind} when length(args) > index ->
        # The server argument names where the message goes, not a module to run.
        server = Enum.at(args, if(index == 2, do: 1, else: 0))
        acc = %{acc | sends: [[kind, shape(Enum.at(args, index)), shape(server)] | acc.sends]}
        args |> List.delete_at(if(index == 2, do: 1, else: 0)) |> walk(known, module, locals, acc)

      _ ->
        acc =
          if target in known,
            do: %{
              acc
              | calls: [["#{inspect(target)}.#{fun}", Enum.map(args, &shape/1)] | acc.calls]
            },
            else: acc

        walk(args, known, module, locals, acc)
    end
  end

  # A struct literal names its module without calling it.
  defp walk({:%, meta, [struct, fields]}, known, module, locals, acc) when is_atom(struct),
    do: walk(fields, known, module, locals, line(acc, meta))

  defp walk({fun, meta, args}, known, module, locals, acc) when is_atom(fun) and is_list(args) do
    acc = line(acc, meta)

    acc =
      if fun in locals,
        do: %{acc | calls: [["#{inspect(module)}.#{fun}", Enum.map(args, &shape/1)] | acc.calls]},
        else: acc

    walk(args, known, module, locals, acc)
  end

  defp walk({left, meta, right}, known, module, locals, acc) when is_list(meta),
    do: walk(right, known, module, locals, walk(left, known, module, locals, line(acc, meta)))

  defp walk({left, right}, known, module, locals, acc),
    do: walk(right, known, module, locals, walk(left, known, module, locals, acc))

  defp walk(list, known, module, locals, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, known, module, locals, &2))

  defp walk(atom, known, _module, _locals, acc) when is_atom(atom) do
    if atom in known, do: %{acc | refs: [inspect(atom) | acc.refs]}, else: acc
  end

  defp walk(_, _, _, _, acc), do: acc

  defp line(acc, meta) do
    case Keyword.get(meta, :line) do
      line when is_integer(line) -> %{acc | last: max(acc.last, line)}
      _ -> acc
    end
  end

  def module(module, known) do
    {^module, beam, _} = :code.get_object_code(module)

    {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(beam, [:debug_info])

    {:ok, debug} = backend.debug_info(:elixir_v1, module, data, [])
    locals = MapSet.new(debug.definitions, fn {{fun, _}, _, _, _} -> fun end)

    functions =
      Enum.reduce(debug.definitions, %{}, fn {{fun, _arity}, kind, meta, clauses}, acc ->
        found =
          for {clause_meta, args, guards, body} <- clauses do
            walked = walk([args, guards, body], known, module, locals)
            start = Keyword.get(clause_meta, :line, Keyword.get(meta, :line, 0))

            %{
              public: kind in [:def, :defmacro],
              macro: kind in [:defmacro, :defmacrop],
              params: Enum.map(args, &shape/1),
              range: [start, max(start, walked.last)],
              calls: Enum.uniq(walked.calls),
              refs: Enum.uniq(walked.refs),
              sends: Enum.uniq(walked.sends)
            }
          end

        Map.update(acc, Atom.to_string(fun), found, &(&1 ++ found))
      end)

    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    line =
      case debug do
        %{line: line} when is_integer(line) -> line
        %{anno: anno} -> :erl_anno.line(anno)
        _ -> 0
      end

    %{
      file: Path.relative_to_cwd(debug.file),
      line: line,
      process: Enum.any?(~w(handle_call handle_cast handle_info), &Map.has_key?(functions, &1)),
      behaviours: for(b <- behaviours, b in known, do: inspect(b)),
      functions: functions
    }
  end

  @doc "A script's calls (through its aliases), whole-module references and required files."
  def script(path, known) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_, {_, calls, refs, requires}} =
      Macro.prewalk(ast, {%{}, [], [], []}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, names} | _]},
        {aliases, c, r, q} ->
          aliases =
            Enum.reduce(names, aliases, fn {:__aliases__, _, parts}, acc ->
              Map.put(acc, List.last(parts), base ++ parts)
            end)

          {:ok, {aliases, c, r, q}}

        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [short]}]]},
        {aliases, c, r, q} ->
          {:ok, {Map.put(aliases, short, parts), c, r, q}}

        {:alias, _, [{:__aliases__, _, parts}]}, {aliases, c, r, q} ->
          {:ok, {Map.put(aliases, List.last(parts), parts), c, r, q}}

        {{:., _, [{:__aliases__, _, [:Code]}, :require_file]}, _, [file | _]}, {aliases, c, r, q}
        when is_binary(file) ->
          {:ok, {aliases, c, r, [file | q]}}

        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args}, {aliases, c, r, q}
        when is_atom(fun) ->
          {{:__call__, [], args}, {aliases, [{resolve(parts, aliases), fun} | c], r, q}}

        {:%, _, [{:__aliases__, _, _}, fields]}, acc ->
          {{:__struct__, [], [fields]}, acc}

        {:__aliases__, _, parts}, {aliases, c, r, q} ->
          {:ok, {aliases, c, [resolve(parts, aliases) | r], q}}

        node, acc ->
          {node, acc}
      end)

    %{
      calls: for({m, f} <- Enum.uniq(calls), m in known, do: "#{inspect(m)}.#{f}"),
      refs: for(m <- Enum.uniq(refs), m in known, do: inspect(m)),
      requires: Enum.uniq(requires)
    }
  end

  defp resolve([first | rest], aliases),
    do: Module.concat(Map.get(aliases, first, [first]) ++ rest)
end

[out | scripts] = System.argv()
{:ok, modules} = :application.get_key(:valimc, :modules)
known = MapSet.new(modules)

File.write!(
  out,
  JSON.encode!(%{
    modules: Map.new(modules, &{inspect(&1), CallGraph.module(&1, known)}),
    scripts: Map.new(scripts, &{Path.basename(&1), CallGraph.script(&1, known)})
  })
)
