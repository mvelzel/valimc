# Runs check scripts in one BEAM for check_vanilla.py (VMC-076d), in order, each as if
# in a BEAM of its own: in a fresh process with its own argv and its output appended to
# its stage's log; afterwards the application environment is restored, the
# `:persistent_term` entries it created (ValiMC's lazily built tables) are erased and
# the processes it left (its group leader's) are killed, so no script reuses what
# another built. An entry with "app" starts the application first (one per BEAM).
#
# With VALIMC_CHECK_COVERAGE=1 each result also names the functions the script ran
# (VMC-076h): BEAM call counts over every ValiMC module, NIF stubs included, reset
# before each script; an anonymous function counts as the function that defines it.
# `check_vanilla.py --changed` selects a stage when a change touches one of them.
#
# Usage: mix run --no-start scripts/run_checks.exs MANIFEST.json RESULTS.jsonl, where the
# manifest is a list of {"script", "args", "log", "app"?}; one result line per script finished.
[manifest, results] = System.argv()
entries = manifest |> File.read!() |> JSON.decode!()
{:ok, out} = File.open(results, [:write, :utf8])
coverage? = System.get_env("VALIMC_CHECK_COVERAGE") == "1"
{:ok, modules} = :application.get_key(:valimc, :modules)

if coverage? do
  Enum.each(modules, &Code.ensure_loaded!/1)
  for module <- modules, do: :erlang.trace_pattern({module, :_, :_}, true, [:call_count])
end

covered = fn ->
  for module <- modules,
      functions =
        for(
          {fun, arity} <- module.module_info(:functions),
          fun not in [:module_info, :__info__],
          match?(
            {:call_count, n} when is_integer(n) and n > 0,
            :erlang.trace_info({module, fun, arity}, :call_count)
          ),
          uniq: true,
          do:
            case Atom.to_string(fun) do
              "-" <> rest -> rest |> String.split("/") |> hd()
              name -> name
            end
        ),
      functions != [],
      into: %{} do
    source = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to_cwd()
    {inspect(module), %{"file" => source, "functions" => Enum.uniq(functions)}}
  end
end

for %{"script" => script, "args" => args, "log" => log} = entry <- entries do
  started = System.monotonic_time(:millisecond)
  env = Application.get_all_env(:valimc)
  terms = MapSet.new(:persistent_term.get(), &elem(&1, 0))
  {:ok, device} = File.open(log, [:append, :utf8])

  IO.write(
    device,
    "$ scripts/#{Path.basename(script)} #{Enum.join(args, " ")}  [run_checks.exs]\n"
  )

  if coverage?,
    do:
      for(module <- modules, do: :erlang.trace_pattern({module, :_, :_}, :restart, [:call_count]))

  if entry["app"], do: {:ok, _} = Application.ensure_all_started(:valimc)

  {pid, ref} =
    spawn_monitor(fn ->
      Process.group_leader(self(), device)
      System.argv(args)

      try do
        Code.eval_file(script)
      rescue
        error ->
          IO.write(Exception.format(:error, error, __STACKTRACE__))
          exit(:check_failed)
      catch
        kind, reason ->
          IO.write(Exception.format(kind, reason, __STACKTRACE__))
          exit(:check_failed)
      end
    end)

  ok =
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason == :normal
    end

  functions = if coverage?, do: covered.()

  for process <- Process.list(),
      process != self(),
      Process.info(process, :group_leader) == {:group_leader, device},
      do: Process.exit(process, :kill)

  for {key, _} <- :persistent_term.get(),
      not MapSet.member?(terms, key),
      do: :persistent_term.erase(key)

  File.close(device)

  for {key, _} <- Application.get_all_env(:valimc),
      not Keyword.has_key?(env, key),
      do: Application.delete_env(:valimc, key)

  Application.put_all_env(valimc: env)
  seconds = (System.monotonic_time(:millisecond) - started) / 1000

  IO.write(
    out,
    JSON.encode!(%{"log" => log, "ok" => ok, "seconds" => seconds, "coverage" => functions}) <>
      "\n"
  )
end

File.close(out)
