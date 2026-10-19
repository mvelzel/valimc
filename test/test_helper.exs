# Each run (and each `--partitions` worker) gets private scratch space for world fixtures.
run_tmp = Path.join(System.tmp_dir!(), "valimc-test-#{System.os_time()}-#{System.pid()}")
File.mkdir_p!(run_tmp)
System.put_env("TMPDIR", run_tmp)
ExUnit.after_suite(fn _ -> File.rm_rf(run_tmp) end)
ExUnit.start()
Code.require_file("support/client.ex", __DIR__)
# Damage/movement fixtures assert exact health. Food tests explicitly enable recovery.
:ok = Valimc.World.Clock.configure({:natural_regeneration, false})
