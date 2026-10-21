defmodule Valimc.Net.Serverbound do
  @moduledoc "Serverbound packet handling for every protocol phase, routed to the owning domain modules (VMC-069)."

  alias Valimc.Protocol.{
    ClientCommand,
    ClientInformation,
    ClientTick,
    Data,
    Encryption,
    Packets,
    Wire
  }

  alias Valimc.Session.{ChunkSender, Commands, Replication}
  alias Valimc.Net.LoginFlow
  alias Valimc.Player.Placement
  alias Valimc.Player.Menus
  alias Valimc.Player.CreativeInventory
  alias Valimc.Player.Mining
  alias Valimc.Player.Movement
  alias Valimc.Player.ItemUse
  alias Valimc.Player.Vitals

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{
    Inventory,
    Players,
    PlayerAbilities,
    PlayerInput,
    PlayerMotion,
    PlayerUse
  }

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
              Valimc.Command.Text.encode(
                Valimc.Command.Text.translatable("multiplayer.disconnect.transfers_disabled")
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
        players: %{max: Valimc.config(:max_players), online: Players.count(), sample: []},
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
      pair = Valimc.LoginKeys.pair()
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

    case Valimc.KeyExchange.start(self(), token, state.key_pair, state.key_challenge, payload) do
      {:ok, job} ->
        timeout = max(job.deadline - System.monotonic_time(:millisecond), 0)
        job = Map.put(job, :timer, Process.send_after(self(), {:key_deadline, token}, timeout))
        Valimc.KeyExchange.activate(job)

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
        client_information(state, payload)

      {"custom_payload", _} ->
        state

      _ ->
        reject(state, "Unexpected configuration packet")
    end
  end

  def handle_packet(%{phase: :play} = state, id, payload) do
    name = Data.name(:play, :serverbound, id)
    after_packet = play_packet(state, name, payload)
    if action?(name, state, after_packet), do: acted(after_packet), else: after_packet
  end

  def handle_packet(state, _, _), do: reject(state, "Unexpected protocol state")

  # VMC-010c: the packets after which vanilla resets a player's idle time
  # (`resetLastActionTime`). Input counts once the client has loaded, movement
  # when the player moved; ValiMC does not repeat each handler's own conditions.
  @actions ~w(player_action use_item_on use_item set_carried_item chat chat_command
              chat_command_signed punch player_command attack interact spectator_action
              client_command container_click place_recipe container_button_click sign_update)

  defp action?(name, _before, _after) when name in @actions, do: true

  defp action?("player_input", before, _after),
    do: Valimc.PlayerInput.loaded?(before.player.input)

  defp action?(name, before, after_packet)
       when name in ["move_player_pos", "move_player_pos_rot"] do
    dx = after_packet.player.x - before.player.x
    dy = after_packet.player.y - before.player.y
    dz = after_packet.player.z - before.player.z
    dx * dx + dy * dy + dz * dz > 1.0e-5
  end

  defp action?(_name, _before, _after), do: false

  defp acted(%{last_action: _} = state),
    do: %{state | last_action: System.monotonic_time(:millisecond)}

  defp acted(state), do: state

  defp play_packet(state, name, payload) do
    case name do
      name
      when state.life_stage != :alive and
             name in [
               "move_player_pos",
               "move_player_pos_rot",
               "move_player_rot",
               "move_player_status_only",
               "player_abilities",
               "player_input",
               "player_command",
               "player_action",
               "set_carried_item",
               "set_creative_mode_slot",
               "container_click",
               "container_close",
               "use_item",
               "use_item_on"
             ] ->
        state

      "client_command" ->
        case ClientCommand.decode(payload) do
          {:ok, :respawn} when state.life_stage in [:sealing_death, :dropping, :dead] ->
            Vitals.continue_life(%{state | respawn_requested: true})

          {:ok, :respawn} ->
            Valimc.Player.Portals.credits_done(state)

          {:ok, _} ->
            state

          {:error, _} ->
            reject(state, "Invalid client lifecycle request")
        end

      "accept_teleportation" ->
        {id, <<x::float-64, y::float-64, z::float-64, _yaw::float-32, _pitch::float-32>>} =
          Wire.take_varint(payload)

        if id != state.teleport, do: reject(state, "Invalid teleport confirmation")

        if abs(x - state.player.x) + abs(y - state.player.y) + abs(z - state.player.z) > 0.01,
          do: reject(state, "Invalid teleport position")

        confirmed = state.teleport_pending
        resume = confirmed and state.login_velocity_pending

        state = %{
          state
          | teleport_pending: false,
            motion_window: nil,
            login_velocity_pending: false
        }

        if confirmed, do: send(self(), :send_chunks)
        if resume, do: Movement.send_velocity(state, state.player.motion.velocity), else: state

      "keep_alive" ->
        <<id::signed-64>> = payload

        case state.keepalive do
          {^id, _} -> %{state | keepalive: nil}
          _ -> reject(state, "Invalid keepalive")
        end

      "move_player_pos" ->
        <<x::float-64, y::float-64, z::float-64, flags>> = payload
        Movement.move(Movement.admit_position(state), %{x: x, y: y, z: z}, flags)

      "move_player_pos_rot" ->
        <<x::float-64, y::float-64, z::float-64, yaw::float-32, pitch::float-32, flags>> =
          payload

        Movement.move(
          Movement.admit_position(state),
          %{x: x, y: y, z: z, yaw: yaw, pitch: pitch},
          flags
        )

      "move_player_rot" ->
        <<yaw::float-32, pitch::float-32, flags>> = payload
        Movement.move(state, %{yaw: yaw, pitch: pitch}, flags)

      "move_player_status_only" ->
        <<flags>> = payload
        Movement.move(state, %{}, flags)

      "client_tick_end" ->
        <<>> = payload
        player = %{state.player | motion: PlayerMotion.finish_tick(state.player.motion)}
        Players.update(self(), player)
        %{state | client_tick: ClientTick.finish(state.client_tick), player: player}

      "chunk_batch_received" ->
        %{state | chunk_sender: ChunkSender.acknowledged(state.chunk_sender, payload)}

      "client_information" ->
        state |> client_information(payload) |> Replication.update_view()

      "player_abilities" ->
        {:ok, abilities} = PlayerAbilities.request_flight(state.player.abilities, payload)

        player = %{
          state.player
          | abilities: abilities,
            motion: PlayerMotion.flight(state.player.motion, abilities.flying)
        }

        Players.update(self(), player)
        %{state | player: player}

      "player_input" ->
        {:ok, input} = PlayerInput.receive_input(state.player.input, payload)
        Movement.update_player_input(state, input)

      "player_command" ->
        {:ok, input} = PlayerInput.receive_command(state.player.input, payload)
        Movement.update_player_input(state, input)

      "player_loaded" ->
        <<>> = payload
        Movement.update_player_input(state, PlayerInput.loaded(state.player.input))

      "change_game_mode" ->
        {_requested_id, <<>>} = Wire.take_varint(payload)
        # All current network sessions are unprivileged; operators are VMC-010.
        state

      "player_action" ->
        Mining.break_block(state, payload)

      "set_carried_item" ->
        <<slot::signed-16>> = payload

        case Inventory.select(state.inventory, slot) do
          {:ok, inventory} ->
            if Menus.selection_pending?(state) do
              send_packets(state, [Packets.held_slot(state.inventory.selected)])
              CreativeInventory.resync_inventory(state)
            else
              send_packets(state, [Packets.held_slot(slot)])

              state =
                if slot != state.inventory.selected and
                     match?(%PlayerUse{hand: :main}, state.active_use),
                   do: ItemUse.stop_item_use(state),
                   else: state

              %{state | inventory: inventory}
            end

          {:error, _} ->
            reject(state, "Invalid hotbar slot")
        end

      "set_creative_mode_slot" ->
        CreativeInventory.creative_slot(state, payload)

      "container_click" ->
        CreativeInventory.inventory_click(state, payload)

      "container_close" ->
        {_container, <<>>} = Wire.take_varint(payload)
        # Native close retires the current menu regardless of the supplied ID.
        if state.table_menu,
          do: Menus.begin_table_close(state),
          else: CreativeInventory.inventory_close(state)

      "use_item_on" ->
        Placement.place_block(state, payload)

      "use_item" ->
        ItemUse.use_item(state, payload)

      "chat" ->
        {message, _metadata} = Wire.take_string(payload, 256)
        state = Commands.throttle_chat(state)
        Players.broadcast({:chat, "<#{state.player.name}> #{message}"})
        state

      "command_suggestion" ->
        {id, payload} = Wire.take_varint(payload)
        {text, <<>>} = Wire.take_string(payload, 32_500)
        source = Valimc.Command.Source.player(state)
        reply = Valimc.Command.Suggestions.suggest(text, source)
        send_packets(state, [Valimc.Command.Suggestions.packet(id, reply)])
        state

      "chat_command" ->
        {command, <<>>} = Wire.take_string(payload, 256)
        run_command(state, command)

      "chat_command_signed" ->
        # Commands with a signable `message` argument (`/say`, `/msg`, `/kick`
        # reasons). ValiMC has no secure chat sessions yet (VMC-009): argument
        # signatures and last-seen acknowledgements are read and not verified.
        {command, payload} = Wire.take_string(payload, 256)
        <<_timestamp::signed-64, _salt::signed-64, payload::binary>> = payload
        {count, payload} = Wire.take_varint(payload)
        if count not in 0..8, do: reject(state, "Invalid command signatures")

        payload =
          Enum.reduce(1..count//1, payload, fn _, payload ->
            {_name, <<_signature::binary-size(256), rest::binary>>} =
              Wire.take_string(payload, 16)

            rest
          end)

        {_offset, <<_acknowledged::binary-size(3), _checksum, rest::binary>>} =
          Wire.take_varint(payload)

        if rest != <<>>, do: reject(state, "Invalid signed command")
        run_command(state, command)

      nil ->
        reject(state, "Unknown packet ID")

      _known_but_unimplemented ->
        state
    end
  end

  # The view distance the client asks for, in configuration and whenever it changes
  # in play (VMC-070); vanilla's tracking clamps it to the server's.
  defp client_information(state, payload) do
    case ClientInformation.decode(payload) do
      {:ok, information} -> %{state | requested_view_distance: information.view_distance}
      {:error, _} -> reject(state, "Invalid client information")
    end
  end

  defp run_command(state, command) do
    # Vanilla `isChatMessageIllegal`: section signs, control characters and DEL.
    if String.match?(command, ~r/[\x{A7}\x{00}-\x{1F}\x{7F}]/u),
      do: reject(state, "Illegal characters in chat")

    state |> Commands.throttle_chat() |> Commands.command(command)
  end
end
