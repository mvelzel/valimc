# Each run (and each `--partitions` worker) gets private scratch space for world fixtures.
run_tmp = Path.join(System.tmp_dir!(), "valimc-test-#{System.os_time()}-#{System.pid()}")
File.mkdir_p!(run_tmp)
System.put_env("TMPDIR", run_tmp)
ExUnit.after_suite(fn _ -> File.rm_rf(run_tmp) end)
# Concurrent modules share the schedulers, and the host may be loaded by other work;
# a passing assert_receive returns at once (VMC-073).
ExUnit.start(assert_receive_timeout: 15_000)
Code.require_file("support/client.ex", __DIR__)
Code.require_file("support/test_bodies.ex", __DIR__)
:ok = Valimc.TestScope.start()
# Groups spawn no mobs unless a test turns natural spawning on for its scope (VMC-042a).
Application.put_env(:valimc, :natural_spawning, false)
# Mobs' goals run unless a test turns them off for its scope (`mob_goals: false`).
Application.put_env(:valimc, :mob_goals, true)
# Damage/movement fixtures assert exact health. Food tests explicitly enable recovery.
:ok = Valimc.World.Clock.configure({:natural_regeneration, false})
