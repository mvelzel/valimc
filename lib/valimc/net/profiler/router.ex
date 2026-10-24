defmodule Valimc.Net.Profiler.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  alias Valimc.Admin.Profiler

  pipeline :report do
    plug(:accepts, ["html", "json"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {Valimc.Net.Profiler.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "cache-control" => "no-store",
      "referrer-policy" => "no-referrer",
      "content-security-policy" =>
        "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; connect-src 'self' ws://127.0.0.1:* ws://localhost:*; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'"
    })

    plug(:load_report)
  end

  scope "/" do
    pipe_through(:report)
    live("/r/:id", Valimc.Net.Profiler.Live, :show, as: :profile)
    get("/data/:id", Valimc.Net.Profiler.Download, :data)
    get("/export/:id/:format", Valimc.Net.Profiler.Download, :export)
  end

  defp load_report(conn, _) do
    id = conn.path_params["id"]

    case if(is_binary(id) and Regex.match?(~r/\A[0-9a-f]{32}\z/, id),
           do: Profiler.report(id),
           else: :error
         ) do
      {:ok, data} -> assign(conn, :report, data)
      :error -> conn |> send_resp(404, Valimc.Net.Profiler.Errors.render("404", %{})) |> halt()
    end
  end
end

defmodule Valimc.Net.Profiler.Download do
  @moduledoc false
  import Plug.Conn
  alias Valimc.Admin.ProfileReport
  def init(action), do: action

  def call(conn, :data),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, :json.encode(conn.assigns.report))

  def call(conn, :export) do
    case conn.path_params["format"] do
      "json" -> attachment(conn, "application/json", "json", :json.encode(conn.assigns.report))
      "html" -> attachment(conn, "text/html", "html", ProfileReport.html(conn.assigns.report))
      _ -> send_resp(conn, 404, "Unknown export format")
    end
  end

  defp attachment(conn, type, extension, body) do
    conn
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"valimc-profile.#{extension}\""
    )
    |> put_resp_content_type(type)
    |> send_resp(200, body)
  end
end
