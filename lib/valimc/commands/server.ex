defmodule Valimc.Commands.Server do
  @moduledoc """
  Server control (VMC-010b, VMC-010c): `/save-all [flush]`, `/save-on`,
  `/save-off` and `/setidletimeout`.

  ValiMC's durable state is its region, player and clock logs, written with
  group commit as things happen. What vanilla's autosave does, the periodic
  save of changed cells and scheduled ticks in each region owner, is what
  `/save-off` stops (`Valimc.World.Saving`). `/save-all` makes every running
  region owner of every dimension save now (with `flush`, waiting until each
  region's writes are durable), checkpoints every online player and writes the
  world clock. It starts no region, whatever the source's dimension.
  """
  alias Valimc.Command.{Error, Feedback, Text}
  alias Valimc.World.Saving

  def save_all(_arguments, source), do: save(source, false)
  def save_all_flush(_arguments, source), do: save(source, true)

  defp save(source, flush) do
    Feedback.success(source, Text.translatable("commands.save.saving"), false)

    for player <- Valimc.Players.all(), do: send(player.pid, :save_player_now)
    regions = owners()

    saved =
      if flush do
        regions
        |> Task.async_stream(fn {pid, _epoch} -> flush_region(pid) end,
          max_concurrency: System.schedulers_online(),
          timeout: 20_000,
          on_timeout: :kill_task
        )
        |> Enum.all?(&match?({:ok, :ok}, &1))
      else
        for {pid, epoch} <- regions, do: send(pid, {:resource, epoch, {:save, :force}})
        true
      end

    clock = Valimc.World.Clock.flush()
    unless saved and clock == :ok, do: Error.fail!("commands.save.failed")
    Feedback.success(source, Text.translatable("commands.save.success"))
    1
  end

  # The registry holds scoped keys (VMC-026b); each is looked up in its own
  # dimension, never admitted.
  @doc false
  def owners do
    for scoped <- Registry.select(Valimc.RegionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        {dimension, key} = Valimc.Dimension.unscope(scoped),
        {:ok, owner} <- [
          Valimc.Dimension.within(dimension, fn -> Valimc.World.existing_owner(key) end)
        ],
        do: owner
  end

  # Item or block writes already in flight become durable through their own
  # group commit, so a busy owner counts as saved.
  defp flush_region(pid) do
    case Valimc.World.Region.flush(pid) do
      :ok -> :ok
      {:error, :item_storage_busy} -> :ok
      other -> other
    end
  catch
    :exit, _ -> :error
  end

  @doc "`/setidletimeout <minutes>` (VMC-010c), saved with the world settings."
  def setidletimeout(%{"minutes" => minutes}, source) do
    with {:error, reason} <- Valimc.World.Settings.put(idle_timeout: minutes),
         do: Error.refuse!("The idle timeout could not be saved (#{inspect(reason)})")

    message =
      if minutes > 0,
        do: Text.translatable("commands.setidletimeout.success", [minutes]),
        else: Text.translatable("commands.setidletimeout.success.disabled")

    Feedback.success(source, message)
    minutes
  end

  def save_on(_arguments, source),
    do: auto(source, true, "commands.save.alreadyOn", "commands.save.enabled")

  def save_off(_arguments, source),
    do: auto(source, false, "commands.save.alreadyOff", "commands.save.disabled")

  defp auto(source, on, already, done) do
    if Saving.set_auto(on) == :unchanged, do: Error.fail!(already)
    Feedback.success(source, Text.translatable(done))
    1
  end
end
