defmodule Valimc.Net.Profiler.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :valimc

  @session [
    store: :cookie,
    key: "_valimc_profile",
    signing_salt: "profile-session",
    same_site: "Lax",
    http_only: true
  ]
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session], timeout: 60_000],
    longpoll: false
  )

  plug(Plug.Static, at: "/assets/phoenix", from: :phoenix, only: ~w(phoenix.mjs))

  plug(Plug.Static,
    at: "/assets/live",
    from: :phoenix_live_view,
    only: ~w(phoenix_live_view.esm.js)
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:valimc, "priv/profiler"},
    only: ~w(app.js style.css fonts)
  )

  plug(Plug.Session, @session)
  plug(Valimc.Net.Profiler.Router)
end

defmodule Valimc.Net.Profiler.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>ValiMC profiler</title>
        <link rel="stylesheet" href="/assets/style.css" />
        <script type="module" src="/assets/app.js"></script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end

defmodule Valimc.Net.Profiler.Errors do
  @moduledoc false
  def render(_, _), do: "Report expired or unknown. Run /spark health or start a new profile."
end
