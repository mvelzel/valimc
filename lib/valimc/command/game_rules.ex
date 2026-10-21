defmodule Valimc.Command.GameRules do
  @moduledoc """
  Game rules read by command feedback (VMC-053) and portals (VMC-026b2);
  vanilla defaults until VMC-053c stores them.
  """
  @defaults %{
    send_command_feedback: true,
    log_admin_commands: true,
    players_nether_portal_default_delay: 80,
    players_nether_portal_creative_delay: 0,
    allow_entering_nether_using_portals: true
  }

  def get(rule), do: :persistent_term.get({__MODULE__, rule}, Map.fetch!(@defaults, rule))
end
