defmodule Valimc.Permissions do
  @moduledoc """
  Command permission levels (VMC-053), vanilla's `PermissionLevel`: 0 all,
  1 moderators, 2 gamemasters, 3 admins, 4 owners.

  Operators come from the `:operators` setting (`VALIMC_OPERATORS`): a list of
  player names, matched case-insensitively like vanilla's `ops.json`, or `:all`
  for a local test server where every player is an operator. Operators get
  `:operator_level` (vanilla's `op-permission-level`, default 4). The full
  operator list, bans and the console are VMC-010.
  """

  def level(name) when is_binary(name) do
    if operator?(name), do: Valimc.config(:operator_level), else: 0
  end

  def operator?(name) do
    case Valimc.config(:operators) do
      :all ->
        true

      names when is_list(names) ->
        Enum.any?(names, &(String.downcase(&1) == String.downcase(name)))
    end
  end

  @doc "The entity event that tells the client its permission level (24..28)."
  def entity_event(level) when level in 0..4, do: 24 + level
end
