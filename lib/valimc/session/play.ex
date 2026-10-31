defmodule Valimc.Session.Play do
  @moduledoc """
  A session's play packets (VMC-069): movement, abilities, input, mining,
  placement, inventory and menus, item use, chat and commands, routed to
  their domain modules. In play a session runs at its group, which applies
  the packets its connection forwards (`Valimc.Net.Link`) in arrival order;
  the connection keeps keepalives, chunk acknowledgements and the client's
  view distance (`packet/3`).
  """

  alias Valimc.Protocol.{ClientCommand, ClientInformation, ClientTick, Data, Packets, Wire}

  alias Valimc.Session.{ChunkSender, Commands, Replication}
  alias Valimc.Player.Placement
  alias Valimc.Player.Menus
  alias Valimc.Player.CreativeInventory
  alias Valimc.Player.Mining
  alias Valimc.Player.Movement
  alias Valimc.Player.ItemUse
  alias Valimc.Player.Vitals

  import Valimc.Protocol.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.Menus.Inventory
  alias Valimc.Player.{PlayerList, Abilities, Input, Motion, Use}

  @doc "A play packet `id` with `payload`; acting packets reset the idle time."
  def handle(state, id, payload) do
    name = Data.name(:play, :serverbound, id)
    after_packet = packet(state, name, payload)
    if action?(name, state, after_packet), do: acted(after_packet), else: after_packet
  end

  # VMC-010c: the packets after which vanilla resets a player's idle time
  # (`resetLastActionTime`). Input counts once the client has loaded, movement
  # when the player moved; ValiMC does not repeat each handler's own conditions.
  @actions ~w(player_action use_item_on use_item set_carried_item chat chat_command
              chat_command_signed punch player_command attack interact spectator_action
              client_command container_click place_recipe container_button_click sign_update)

  defp action?(name, _before, _after) when name in @actions, do: true

  defp action?("player_input", before, _after),
    do: Valimc.Player.Input.loaded?(before.player.input)

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

  @doc "One play packet, by name, applied to the session."
  def packet(state, name, payload) do
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
               "select_trade",
               "container_button_click",
               "rename_item",
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

        # Vanilla's `handleAcceptTeleportPacket` ignores any but the awaited
        # teleport: a client confirms one the server already replaced (a
        # command's, then a portal's or a travel's) before it sees the next.
        if id != state.teleport do
          state
        else
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

          if confirmed and state.socket != nil, do: send(self(), :send_chunks)
          if resume, do: Movement.send_velocity(state, state.player.motion.velocity), else: state
        end

      "keep_alive" ->
        <<id::signed-64>> = payload

        case state.keepalive do
          {^id, sent} ->
            Valimc.Data.ProfileTicks.rtt(
              state.connection,
              System.monotonic_time(:millisecond) - sent
            )

            %{state | keepalive: nil}

          _ ->
            reject(state, "Invalid keepalive")
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
        player = %{state.player | motion: Motion.finish_tick(state.player.motion)}
        PlayerList.update(state.connection, player)

        %{
          state
          | client_tick: ClientTick.finish(state.client_tick),
            player: player,
            motion_window: nil
        }

      "chunk_batch_received" ->
        %{state | chunk_sender: ChunkSender.acknowledged(state.chunk_sender, payload)}

      "client_information" ->
        state |> client_information(payload) |> Replication.update_view()

      "player_abilities" ->
        {:ok, abilities} = Abilities.request_flight(state.player.abilities, payload)

        player = %{
          state.player
          | abilities: abilities,
            motion: Motion.flight(state.player.motion, abilities.flying)
        }

        PlayerList.update(state.connection, player)
        %{state | player: player}

      "player_input" ->
        {:ok, input} = Input.receive_input(state.player.input, payload)
        Movement.update_player_input(state, input)

      "player_command" ->
        {:ok, input} = Input.receive_command(state.player.input, payload)
        state = Movement.update_player_input(state, input)

        # Leaving the bed (VMC-040a, `STOP_SLEEPING`).
        case Input.decode_command(payload) do
          {:ok, {_, :stop_sleeping, _}} -> Valimc.Player.Sleep.stop(state, false)
          _ -> state
        end

      "player_loaded" ->
        <<>> = payload
        Movement.update_player_input(state, Input.loaded(state.player.input))

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
            send_packets(state, [Packets.held_slot(slot)])

            state =
              if slot != state.inventory.selected and
                   match?(%Use{hand: :main}, state.active_use),
                 do: ItemUse.stop_item_use(state),
                 else: state

            %{state | inventory: inventory}

          {:error, _} ->
            reject(state, "Invalid hotbar slot")
        end

      "set_creative_mode_slot" ->
        CreativeInventory.creative_slot(state, payload)

      "container_click" ->
        CreativeInventory.inventory_click(state, payload)

      "select_trade" ->
        Valimc.Player.Merchant.select(state, payload)

      # An enchanting table's buttons (VMC-038a).
      "container_button_click" ->
        Valimc.Player.Enchanting.button(state, payload)

      # An anvil's rename field (VMC-038b).
      "rename_item" ->
        Valimc.Player.Anvil.rename(state, payload)

      "container_close" ->
        {_container, <<>>} = Wire.take_varint(payload)
        # Native close retires the current menu regardless of the supplied ID.
        if state.table_menu, do: Menus.close(state), else: Menus.closed(state)

      "use_item_on" ->
        Placement.place_block(state, payload)

      "use_item" ->
        ItemUse.use_item(state, payload)

      "attack" ->
        Valimc.Player.Attack.attack(state, payload)

      "interact" ->
        Valimc.Player.Interact.interact(state, payload)

      "punch" ->
        Valimc.Player.Attack.punch(state)

      "chat" ->
        {message, _metadata} = Wire.take_string(payload, 256)
        legal!(state, message)
        state = Commands.throttle_chat(state)
        PlayerList.broadcast({:chat, "<#{state.player.name}> #{message}"})
        state

      "command_suggestion" ->
        {id, payload} = Wire.take_varint(payload)
        {text, <<>>} = Wire.take_string(payload, 32_500)
        Commands.suggest(state, id, text)

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
  def client_information(state, payload) do
    case ClientInformation.decode(payload) do
      {:ok, information} -> %{state | requested_view_distance: information.view_distance}
      {:error, _} -> reject(state, "Invalid client information")
    end
  end

  defp run_command(state, command) do
    legal!(state, command)
    state |> Commands.throttle_chat() |> Commands.command(command)
  end

  # Vanilla `isChatMessageIllegal`, for chat and commands alike: section signs,
  # control characters and DEL end the session.
  defp legal!(state, text) do
    if String.match?(text, ~r/[\x{A7}\x{00}-\x{1F}\x{7F}]/u),
      do: reject(state, "Illegal characters in chat")
  end
end
