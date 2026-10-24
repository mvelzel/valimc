defmodule Valimc.Admin.ProfileReport do
  @moduledoc "Self-contained report; no CDN or spark service dependency."
  @template Path.expand("../../../priv/profiler/viewer.html", __DIR__)
  @external_resource @template
  @html File.read!(@template)
  @license_path Path.expand("../../../priv/profiler/fonts/OFL.txt", __DIR__)
  @external_resource @license_path
  @license File.read!(@license_path)
           |> String.replace("&", "&amp;")
           |> String.replace("<", "&lt;")
  @external_resource Path.expand(
                       "../../../priv/profiler/fonts/JetBrainsMono-Regular.woff2",
                       __DIR__
                     )
  @external_resource Path.expand("../../../priv/profiler/fonts/JetBrainsMono-Bold.woff2", __DIR__)
  @stylesheet Path.expand("../../../priv/profiler/style.css", __DIR__)
  @external_resource @stylesheet
  @css File.read!(@stylesheet)
       |> String.replace(
         "/assets/fonts/JetBrainsMono-Regular.woff2",
         "data:font/woff2;base64," <>
           Base.encode64(
             File.read!(
               Path.expand("../../../priv/profiler/fonts/JetBrainsMono-Regular.woff2", __DIR__)
             )
           )
       )
       |> String.replace(
         "/assets/fonts/JetBrainsMono-Bold.woff2",
         "data:font/woff2;base64," <>
           Base.encode64(
             File.read!(
               Path.expand("../../../priv/profiler/fonts/JetBrainsMono-Bold.woff2", __DIR__)
             )
           )
       )

  def html(data, endpoint \\ nil) do
    data =
      if is_nil(endpoint) and Map.get(data, :status) in ["running", "live"],
        do: Map.put(data, :status, "snapshot"),
        else: data

    payload = JSON.encode!(%{data: data, endpoint: endpoint})
    # JSON lives in script text. Escape HTML delimiters, including </script>.
    payload =
      payload
      |> String.replace("<", "\\u003c")
      |> String.replace(">", "\\u003e")
      |> String.replace("&", "\\u0026")
      |> String.replace(<<0xE2, 0x80, 0xA8>>, "\\u2028")
      |> String.replace(<<0xE2, 0x80, 0xA9>>, "\\u2029")

    @html
    |> String.replace("__PROFILE_STYLE__", @css)
    |> String.replace("__FONT_LICENSE__", @license)
    |> String.replace("__PROFILE_PAYLOAD__", payload)
  end
end
