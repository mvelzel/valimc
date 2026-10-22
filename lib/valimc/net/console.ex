defmodule Valimc.Net.Console do
  @moduledoc """
  The server console (VMC-010f), vanilla's `DedicatedServer` console thread:
  each line read from standard input runs as a command from the console
  source (`Valimc.Commands.Source.console/0`, level 4, a leading `/` optional),
  one at a time, and its feedback prints in English. Operators see the console's
  broadcasts as `[Server: …]`. The reader stops at end of input, as it does when
  the server runs without a terminal; `VALIMC_CONSOLE=false` turns it off.
  """
  use Task, restart: :transient

  def start_link(_opts), do: Task.start_link(&read/0)

  defp read do
    case IO.gets(:stdio, "") do
      line when is_binary(line) ->
        line |> String.trim_trailing("\n") |> String.trim_trailing("\r") |> run()
        read()

      _eof_or_error ->
        :ok
    end
  end

  defp run(line) do
    Valimc.Commands.execute_console(line)
  catch
    kind, reason ->
      require Logger
      Logger.error("Console command failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end
end
