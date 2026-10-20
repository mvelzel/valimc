defmodule Mix.Tasks.Valimc.Export do
  @shortdoc "Export a ValiMC world to vanilla 26.3 Anvil files"
  @moduledoc """
      mix valimc.export VALIMC_WORLD VANILLA_WORLD

  See `Valimc.Anvil.Export`. Run with the server stopped.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    Valimc.Anvil.Export.cli(args)
  end
end
