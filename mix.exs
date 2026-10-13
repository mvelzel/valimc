defmodule Valimc.MixProject do
  use Mix.Project

  def project do
    [
      app: :valimc,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [],
      test_ignore_filters: [~r"test/support/"],
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Valimc.Application, []}]
  end
end
