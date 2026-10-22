defmodule Valimc.Admin.Permissions do
  @moduledoc """
  Command permission levels (VMC-053), vanilla's `PermissionLevel`: 0 all,
  1 moderators, 2 gamemasters, 3 admins, 4 owners.

  A player's level is their `ops.json` entry's (`Valimc.Admin.Lists`, VMC-010a),
  else 0. The `:operators` setting `:all` (a local test server) makes every
  player an operator at `:operator_level` (vanilla's `op-permission-level`,
  default 4); named operators are added to `ops.json` at startup.
  """
  alias Valimc.Admin.Lists

  def level(%{uuid: uuid}) do
    cond do
      Valimc.config(:operators) == :all -> Valimc.config(:operator_level)
      op = Lists.op(uuid) -> elem(op, 0)
      true -> 0
    end
  end

  @doc "Whether the player is an operator (`PlayerList.isOp`), whatever their level."
  def operator?(%{uuid: uuid}), do: Valimc.config(:operators) == :all or Lists.op(uuid) != nil

  @doc "The entity event that tells the client its permission level (24..28)."
  def entity_event(level) when level in 0..4, do: 24 + level
end
