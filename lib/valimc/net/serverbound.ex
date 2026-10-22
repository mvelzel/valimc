defmodule Valimc.Net.Serverbound do
  @moduledoc "Serverbound packet handling for every protocol phase, routed to the owning domain modules (VMC-069)."

  alias Valimc.Protocol.{Data, Encryption, Packets, Wire}

  alias Valimc.Net.LoginFlow

  import Valimc.Protocol.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.Player.PlayerList

  def handle_packet(%{phase: :handshake} = state, 0, payload) do
    {version, payload} = Wire.take_varint(payload)
    {_host, payload} = Wire.take_string(payload, 255)
    <<_port::16, payload::binary>> = payload
    {intent, <<>>} = Wire.take_varint(payload)

    case intent do
      1 ->
        %{state | phase: :status, protocol: version}

      intent when intent in [2, 3] ->
        state = %{state | phase: :login, protocol: version, step: :hello}

        if version != Valimc.protocol_version(),
          do: reject(state, "Use Minecraft Java #{Valimc.version()}")

        # A transfer (`/transfer` on another server) needs `accepts-transfers`.
        if intent == 3 and not Valimc.config(:accepts_transfers),
          do:
            reject(
              state,
              Valimc.Text.encode(
                Valimc.Text.translatable("multiplayer.disconnect.transfers_disabled")
              )
            )

        state

      _ ->
        reject(state, "Unsupported handshake intent")
    end
  end

  def handle_packet(%{phase: :status} = state, 0, <<>>) do
    response =
      :json.encode(%{
        version: %{name: "ValiMC #{Valimc.version()}", protocol: Valimc.protocol_version()},
        players: %{max: Valimc.config(:max_players), online: PlayerList.count(), sample: []},
        description: %{text: Valimc.config(:motd)},
        enforcesSecureChat: false
      })
      |> IO.iodata_to_binary()

    send_packets(state, [Packets.packet("status_response", Wire.string(response), :status)])
    state
  end

  def handle_packet(%{phase: :status} = state, 1, <<token::64>>) do
    send_packets(state, [Packets.packet("pong_response", <<token::64>>, :status)])
    throw({:disconnect, :status_complete})
  end

  def handle_packet(%{phase: :login, step: :hello} = state, 0, payload) do
    {name, <<_provided_uuid::binary-size(16)>>} = Wire.take_string(payload, 16)

    if not Regex.match?(~r/\A[A-Za-z0-9_]{1,16}\z/, name),
      do: reject(state, "Invalid player name")

    if state.encryption_requested do
      pair = Valimc.Net.LoginKeys.pair()
      challenge = Encryption.challenge()
      send_packets(state, [Encryption.hello(pair, challenge, state.online_mode)])

      %{
        state
        | step: :key,
          login_name: name,
          key_pair: pair,
          key_public: pair.encoded,
          key_challenge: challenge
      }
    else
      LoginFlow.start_player_login(state, name)
    end
  end

  def handle_packet(%{phase: :login, step: :key} = state, 1, payload) do
    if byte_size(payload) > 266, do: reject(state, "Invalid login encryption response")
    token = make_ref()

    case Valimc.Net.LoginJobs.key_exchange(
           self(),
           token,
           state.key_pair,
           state.key_challenge,
           payload
         ) do
      {:ok, job} ->
        timeout = max(job.deadline - System.monotonic_time(:millisecond), 0)
        job = Map.put(job, :timer, Process.send_after(self(), {:key_deadline, token}, timeout))
        Valimc.Net.LoginJobs.activate(job)

        %{state | step: :key_job, key_job: job, key_pair: nil, key_challenge: nil}

      _ ->
        reject(state, "Server busy; please retry")
    end
  end

  def handle_packet(%{phase: :login, step: :ack} = state, 3, <<>>) do
    state = %{state | phase: :configuration, step: :known_packs}
    send_packets(state, [Packets.known_packs()])
    state
  end

  def handle_packet(%{phase: :configuration} = state, id, payload) do
    case {Data.name(:configuration, :serverbound, id), state.step} do
      {"select_known_packs", :known_packs} ->
        {count, payload} = Wire.take_varint(payload)
        if count != 1, do: reject(state, "The vanilla 26.3 core data pack is required")
        {namespace, payload} = Wire.take_string(payload)
        {pack_id, payload} = Wire.take_string(payload)
        {version, <<>>} = Wire.take_string(payload)

        if {namespace, pack_id, version} != {"minecraft", "core", Valimc.version()},
          do: reject(state, "The vanilla 26.3 core data pack is required")

        send_packets(state, Packets.configuration())
        %{state | step: :finish}

      {"finish_configuration", :finish} when payload == <<>> ->
        LoginFlow.enter_world(state)

      {"client_information", _} ->
        Valimc.Session.Play.client_information(state, payload)

      {"custom_payload", _} ->
        state

      _ ->
        reject(state, "Unexpected configuration packet")
    end
  end

  # In play the session runs at its owner (VMC-077i3): the connection keeps
  # keepalives, chunk acknowledgements and the client's view distance, and
  # forwards every other packet in order.
  def handle_packet(%{phase: :play, owner: owner} = state, id, payload) when owner != nil do
    case Data.name(:play, :serverbound, id) do
      "keep_alive" ->
        Valimc.Session.Play.packet(state, "keep_alive", payload)

      "chunk_batch_received" ->
        Valimc.Session.Play.packet(state, "chunk_batch_received", payload)

      "client_information" ->
        Valimc.Session.Play.packet(state, "client_information", payload)

      nil ->
        reject(state, "Unknown packet ID")

      _ ->
        Valimc.Net.Link.forward(state, {:input, id, payload})
        state
    end
  end

  def handle_packet(%{phase: :play} = state, id, payload),
    do: Valimc.Session.Play.handle(state, id, payload)

  def handle_packet(state, _, _), do: reject(state, "Unexpected protocol state")
end
