defmodule Valimc.Net.ProfileWeb do
  @moduledoc "Phoenix/LiveView report service, local by default and isolated from simulation owners."
  use Supervisor
  alias Valimc.Net.Profiler.{Endpoint, Limits}

  def start_link(opts \\ []) do
    with {:ok, pid} <- Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      Valimc.Admin.Profiler.viewer_port(fn ->
        {:ok, {_, port}} = Endpoint.server_info(:http)
        port
      end)

      {:ok, pid}
    end
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:valimc, :profiler_port, 0))

    endpoint = [
      server: true,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      http: [
        ip: Application.get_env(:valimc, :profiler_ip, {127, 0, 0, 1}),
        port: port,
        thousand_island_options: [
          num_acceptors: 2,
          num_connections: 32,
          read_timeout: 2000,
          max_connections_retry_count: 0,
          transport_options: [backlog: 16]
        ],
        http_1_options: [
          max_request_line_length: 4096,
          max_header_length: 4096,
          max_header_count: 32
        ],
        http_2_options: [enabled: false],
        websocket_options: [max_frame_size: 16_384, max_fragmented_message_size: 16_384]
      ]
    ]

    # Restarting admission also closes existing sockets: its limit cannot reset
    # underneath surviving LiveViews. Limits monitors views rather than tokens.
    Supervisor.init(
      [
        {Phoenix.PubSub, name: Valimc.ProfilePubSub},
        Limits,
        {Endpoint, endpoint}
      ],
      strategy: :rest_for_one
    )
  end
end
