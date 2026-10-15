ExUnit.start()
Code.require_file("support/client.ex", __DIR__)
# Damage/movement fixtures assert exact health. Food tests explicitly enable recovery.
:ok = Valimc.World.Clock.configure({:natural_regeneration, false})
