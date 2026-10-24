defmodule Valimc.MixProject do
  use Mix.Project

  def project do
    [
      app: :valimc,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:valimc_native] ++ Mix.compilers(),
      deps: deps(),
      test_ignore_filters: [~r"test/support/"],
      elixirc_options: [warnings_as_errors: true],
      aliases: aliases()
    ]
  end

  def cli, do: [preferred_envs: ["test.fast": :test]]

  # Socket-driven suites carry `@moduletag :tcp` and live-generation or portal suites
  # `@moduletag :slow`; the fast loop leaves both to broad checks.
  defp aliases, do: ["test.fast": ["test --exclude tcp --exclude slow"]]

  def application do
    [extra_applications: [:logger, :crypto, :ssl], mod: {Valimc.Application, []}]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_live_view, "~> 1.2.13"},
      {:phoenix_html, "~> 4.3"},
      {:bandit, "~> 1.13.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # Build-time only: compiles `native/valimc_nif` (keep the crate on the same minor).
      {:rustler, "~> 0.38.0", runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:benchee, "~> 1.3", only: [:dev, :bench], runtime: false}
    ]
  end
end

defmodule Mix.Tasks.Compile.ValimcNative do
  use Mix.Task.Compiler

  @moduledoc false

  # Rustler's compiler always copies into source priv/native. Own this output
  # step here: each Mix build holds physical assets and its own native library.
  def run(_args) do
    config = Application.fetch_env!(:valimc, Valimc.Native)
    features = Keyword.get(config, :features, [])
    args = ["rustc", "--release", "--message-format=json-render-diagnostics", "--quiet"]
    args = if features == [], do: args, else: args ++ ["--features", Enum.join(features, ",")]

    case System.cmd("cargo", args,
           cd: "native/valimc_nif",
           env: Keyword.fetch!(config, :env),
           into: struct(Rustler.BuildResults),
           lines: 1024
         ) do
      {%{artifacts: artifacts}, 0} ->
        artifact = Enum.find(artifacts, &(&1.kind == :lib and &1.name == "valimc_nif"))
        if artifact == nil, do: Mix.raise("Cargo did not return the valimc_nif library")
        priv = Path.join(Mix.Project.app_path(), "priv")
        # rm_rf removes a legacy symlink itself, never its source assets.
        File.rm_rf!(priv)
        File.mkdir_p!(priv)

        for name <- File.ls!("priv"), name != "native" do
          File.cp_r!(Path.join("priv", name), Path.join(priv, name))
        end

        {:valimc, load_from} = Keyword.fetch!(config, :load_from)
        extension = if match?({:win32, _}, :os.type()), do: ".dll", else: ".so"
        destination = Path.join(Mix.Project.app_path(), load_from <> extension)
        File.mkdir_p!(Path.dirname(destination))
        temporary = destination <> ".#{System.pid()}.new"
        File.cp!(artifact.filename, temporary)
        File.rename!(temporary, destination)
        {:ok, []}

      {_, code} ->
        Mix.raise("Cargo failed to compile valimc_nif (exit #{code})")
    end
  end
end
