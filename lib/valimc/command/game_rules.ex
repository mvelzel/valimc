defmodule Valimc.Command.GameRules do
  @moduledoc "Game rules read by command feedback (VMC-053); vanilla defaults until VMC-053c stores them."
  @defaults %{send_command_feedback: true, log_admin_commands: true}

  def get(rule), do: :persistent_term.get({__MODULE__, rule}, Map.fetch!(@defaults, rule))
end
