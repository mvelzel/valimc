defmodule Valimc do
  @moduledoc "Elixir/OTP Minecraft Java server. See README for the implemented compatibility slice."
  @scoped Valimc.ScopedConfig

  def config(key), do: Application.fetch_env!(:valimc, key)

  @doc """
  `config/1` for one owner `scope` (a region key or player UUID), read once at owner
  start. Concurrent tests give their owners a private world path or toggle through
  `{{scope, key}, value}` rows in the `Valimc.ScopedConfig` table; only the test
  helper creates it, so elsewhere this is always `config/1`.
  """
  def config(key, scope) do
    with table when table != :undefined <- :ets.whereis(@scoped),
         [{_, value}] <- :ets.lookup(table, {scope, key}) do
      value
    else
      _ -> config(key)
    end
  end

  defdelegate version, to: Valimc.Version, as: :minecraft
  defdelegate protocol_version, to: Valimc.Version, as: :protocol
end
