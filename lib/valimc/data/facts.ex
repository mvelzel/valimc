defmodule Valimc.Data.Facts do
  @moduledoc """
  Generated facts in `priv`, decoded at compile time.

  `use Valimc.Data.Facts, "dir/file.json"` marks the file as an external resource,
  decodes it once and sets `@facts`; the module then builds its own terms from
  it. A module that reads a second file names its attribute:
  `use Valimc.Data.Facts, file: "dir/other.json", as: :other_facts`. Each file has
  one decoding module, and every other reader asks that module.

  Files too large to keep as terms (loot tables, translations, the command
  tree) or that go to Rust as they are (worldgen) are read at run time from
  the installed application with `read!/1`.

  A file stamped with a release (`version`, `data_version`, `protocol`,
  `server_sha1`) must carry the pinned value of every stamp it has
  (`Valimc.Data.Version`). JSON `null` decodes to `nil`.
  """
  @priv Path.expand("../../../priv", __DIR__)
  @stamps ~w(version data_version protocol server_sha1)

  defmacro __using__(file) when is_binary(file), do: using(file, :facts)

  defmacro __using__(opts) when is_list(opts),
    do: using(Keyword.fetch!(opts, :file), Keyword.get(opts, :as, :facts))

  defp using(file, name) do
    quote bind_quoted: [file: file, name: name] do
      @external_resource Valimc.Data.Facts.path(file)
      Module.put_attribute(__MODULE__, name, Valimc.Data.Facts.load!(file))
    end
  end

  @doc "The absolute path of a `priv` file in the source tree."
  def path(file), do: Path.join(@priv, file)

  @doc "Decode a `priv` file of the source tree (at compile time), checking its stamps."
  def load!(file), do: file |> path() |> decode!(file)

  @doc "Decode a `priv` file of the installed application (at run time), checking its stamps."
  def read!(file), do: Application.app_dir(:valimc, Path.join("priv", file)) |> decode!(file)

  defp decode!(path, file) do
    facts = path |> File.read!() |> JSON.decode!()

    if is_map(facts) and
         not Valimc.Data.Version.stamped?(facts, Enum.filter(@stamps, &is_map_key(facts, &1))),
       do: raise("priv/#{file} was generated for another Minecraft release")

    facts
  end
end
