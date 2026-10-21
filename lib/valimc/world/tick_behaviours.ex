defmodule Valimc.World.TickBehaviours do
  @moduledoc """
  The tick behaviours a region owner runs (VMC-066): the `Valimc.Block.Behaviour`
  modules whose callbacks react to ticks, by state. Tests may configure extra
  modules (`:tick_behaviours`), each with `states/0` and the same callbacks.
  """

  @doc "Extra configured behaviour modules (`:tick_behaviours`, scoped per region; tests)."
  def modules(key), do: Valimc.config(:tick_behaviours, key)

  @doc """
  State id => module, built once per owner: `Valimc.Block` behaviours that react
  to ticks, plus any extra configured modules (tests).
  """
  def index(modules) do
    configured = for module <- modules, state <- module.states(), into: %{}, do: {state, module}
    index = Map.merge(Map.new(Valimc.Block.tick_states()), configured)
    # Owners test callbacks with `function_exported?/3`, which does not load modules.
    index |> Map.values() |> Enum.uniq() |> Enum.each(&Code.ensure_loaded!/1)
    index
  end
end
