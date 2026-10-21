defmodule Valimc.Facts do
  @moduledoc """
  Generated facts in `priv`, decoded at compile time.

  `use Valimc.Facts, "dir/file.json"` marks the file as an external resource,
  decodes it once and sets `@facts`; the module then builds its own terms from
  it. Each file has one decoding module, and every other reader asks that
  module. A file stamped with a release (`version`, `data_version`,
  `server_sha1`) must carry the pinned one (`Valimc.Version`).
  """
  @priv Path.expand("../../priv", __DIR__)

  defmacro __using__(file) do
    quote bind_quoted: [file: file] do
      @external_resource Valimc.Facts.path(file)
      @facts Valimc.Facts.load!(file)
    end
  end

  @doc "The absolute path of a `priv` file."
  def path(file), do: Path.join(@priv, file)

  @doc "Decode a `priv` JSON file, checking its release stamps when it has them."
  def load!(file) do
    facts = file |> path() |> File.read!() |> JSON.decode!()

    if is_map(facts) and Map.has_key?(facts, "version") and not Valimc.Version.stamped?(facts),
      do: raise("priv/#{file} was generated for another Minecraft release")

    facts
  end
end
