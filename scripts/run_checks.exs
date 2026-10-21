# Runs several check scripts in one BEAM for check_vanilla.py (VMC-076d), in order:
# each in a fresh process with its own argv, its output appended to its stage's log,
# and the application environment restored after it.
# Usage: mix run --no-start scripts/run_checks.exs MANIFEST.json RESULTS.jsonl, where the
# manifest is a list of {"script", "args", "log"}; one result line per script finished.
[manifest, results] = System.argv()
entries = manifest |> File.read!() |> JSON.decode!()
{:ok, out} = File.open(results, [:write, :utf8])

for %{"script" => script, "args" => args, "log" => log} <- entries do
  started = System.monotonic_time(:millisecond)
  env = Application.get_all_env(:valimc)
  {:ok, device} = File.open(log, [:append, :utf8])

  IO.write(
    device,
    "$ scripts/#{Path.basename(script)} #{Enum.join(args, " ")}  [one BEAM with others]\n"
  )

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

  File.close(device)

  for {key, _} <- Application.get_all_env(:valimc),
      not Keyword.has_key?(env, key),
      do: Application.delete_env(:valimc, key)

  Application.put_all_env(valimc: env)
  seconds = (System.monotonic_time(:millisecond) - started) / 1000
  IO.write(out, JSON.encode!(%{"log" => log, "ok" => ok, "seconds" => seconds}) <> "\n")
end

File.close(out)
