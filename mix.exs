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
      elixirc_options: [warnings_as_errors: true],
      aliases: aliases()
    ]
  end

  def cli, do: [preferred_envs: ["test.fast": :test]]

  # Socket-driven suites carry `@moduletag :tcp`; the fast loop leaves them to broad checks.
  defp aliases, do: ["test.fast": ["test --exclude tcp"]]

  def application do
    [extra_applications: [:logger, :crypto, :ssl], mod: {Valimc.Application, []}]
  end
end
