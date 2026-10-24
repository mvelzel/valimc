defmodule Valimc.Admin.ProfileReport do
  @moduledoc "Self-contained report; no CDN or spark service dependency."
  @template Path.expand("../../../priv/profiler/viewer.html", __DIR__)
  @external_resource @template
  @html File.read!(@template)

  def html(data, endpoint \\ nil) do
    payload = :json.encode(%{data: data, endpoint: endpoint}) |> IO.iodata_to_binary()
    # JSON lives in script text. Escape HTML delimiters, including </script>.
    payload =
      payload
      |> String.replace("<", "\\u003c")
      |> String.replace(">", "\\u003e")
      |> String.replace("&", "\\u0026")
      |> String.replace(<<0xE2, 0x80, 0xA8>>, "\\u2028")
      |> String.replace(<<0xE2, 0x80, 0xA9>>, "\\u2029")

    String.replace(@html, "__PROFILE_PAYLOAD__", payload)
  end
end
