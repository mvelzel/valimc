defmodule Mix.Tasks.Valimc.Import do
  @shortdoc "Import a vanilla 26.3 world into a new ValiMC world"
  @moduledoc """
      mix valimc.import VANILLA_WORLD VALIMC_WORLD

  See `Valimc.Anvil.Import`. Run with the server stopped.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    Valimc.Anvil.Import.cli(args)
  end
end
