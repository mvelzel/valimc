defmodule Valimc.Connection do
  use GenServer, restart: :temporary, shutdown: 15_000

  @moduledoc "A socket-owning process per player, including their protocol and connection-local state."
  alias Valimc.Protocol.{Data, InventoryClick, ItemStack, ItemTypes, Packets, Wire}
  alias Valimc.{Inventory, Metrics, Players, PlayerStore, World}
  import Bitwise

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  def deliver(pid, event) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} ->
        if size <= Valimc.config(:max_mailbox) do
          send(pid, {:event, event})
          :ok
        else
          Metrics.add(:slow_clients_disconnected)
          Process.exit(pid, :kill)
          :overloaded
        end

      nil ->
        :closed
    end
  end

  @impl true
  def init(socket) do
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)

    {:ok,
     %{
       socket: socket,
       phase: :handshake,
       step: nil,
       threshold: nil,
       protocol: nil,
       buffer: <<>>,
       player: nil,
       player_store: nil,
       store_monitor: nil,
       save_ref: nil,
       chunks: MapSet.new(),
       regions: MapSet.new(),
       pending: [],
       batch_pending: false,
       peers: %{},
       outbound: [],
       inventory: Inventory.new(),
       window: System.monotonic_time(:second),
       packets: 0,
       bytes: 0,
       logical_bytes: 0,
       keepalive: nil,
       teleport: 1,
       teleport_pending: true,
       center: nil,
       active: false
     }}
  end

  @impl true
  def handle_info(:activate, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    Process.send_after(self(), :login_deadline, Valimc.config(:login_timeout_ms))
    Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))
    Metrics.add(:connections_accepted)
    {:noreply, %{state | active: true}}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    guard_connection(state, fn ->
      state = reset_window(state)
      bytes = state.bytes + byte_size(data)
      if bytes > Valimc.config(:bytes_per_second), do: reject(state, "Inbound byte rate exceeded")

      if byte_size(state.buffer) + byte_size(data) > Valimc.config(:max_packet_bytes) + 5,
        do: reject(state, "Receive buffer exceeded")

      consume(%{state | buffer: state.buffer <> data, bytes: bytes, active: false}, 64)
    end)
  end

  def handle_info(:drain, state), do: guard_connection(state, fn -> consume(state, 64) end)
  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  def handle_info(:save_player, state) do
    Process.send_after(self(), :save_player, Valimc.config(:player_save_interval_ms))

    if state.phase == :play and state.save_ref == nil do
      ref = make_ref()
      PlayerStore.checkpoint(state.player_store, state.player, ref)
      Process.send_after(self(), {:save_deadline, ref}, 5000)
      {:noreply, %{state | save_ref: ref}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:player_saved, ref, :ok}, %{save_ref: ref} = state),
    do: {:noreply, %{state | save_ref: nil}}

  def handle_info({:player_saved, ref, {:error, _}}, %{save_ref: ref} = state),
    do: guard_connection(state, fn -> reject(state, "Player save failed") end)

  def handle_info({:save_deadline, ref}, %{save_ref: ref} = state),
    do: guard_connection(state, fn -> reject(state, "Player save timed out") end)

  def handle_info({:save_deadline, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{store_monitor: ref} = state),
    do: guard_connection(state, fn -> reject(state, "Player storage stopped") end)

  def handle_info(:login_deadline, %{phase: :play} = state), do: {:noreply, state}
  def handle_info(:login_deadline, state), do: {:stop, :normal, state}

  def handle_info(:keepalive, state) do
    guard_connection(state, fn ->
      Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))

      if state.phase == :play do
        now = System.monotonic_time(:millisecond)
        timeout = Valimc.config(:keepalive_timeout_ms)

        case state.keepalive do
          {_, sent} when now - sent > timeout ->
            reject(state, "Keepalive timed out")

          nil ->
            id = System.unique_integer([:positive])
            send_packets(state, [Packets.packet("keep_alive", <<id::signed-64>>)])
            {:noreply, %{state | keepalive: {id, now}}}

          _ ->
            {:noreply, state}
        end
      else
        {:noreply, state}
      end
    end)
  end

  def handle_info(:publish_movement, state) do
    guard_connection(state, fn ->
      if state.phase == :play do
        Process.send_after(self(), :publish_movement, 50)

        nearby = Players.nearby(state.regions)

        state =
          Enum.reduce(nearby, state, fn pid, acc ->
            case Players.get(pid) do
              {:ok, player} -> track_peer(acc, player, :buffer)
              :error -> acc
            end
          end)

        state =
          Enum.reduce(state.peers, state, fn {pid, player}, acc ->
            if MapSet.member?(nearby, pid),
              do: acc,
              else: %{
                emit_peer_packets(
                  acc,
                  [Packets.remove_entity(player), Packets.remove_info(player)],
                  :buffer
                )
                | peers: Map.delete(acc.peers, pid)
              }
          end)

        packets = state.outbound |> Enum.reverse() |> List.flatten()
        send_packets(state, packets)

        {:noreply, %{state | outbound: []}}
      else
        {:noreply, state}
      end
    end)
  end

  def handle_info(:send_chunks, state),
    do: guard_connection(state, fn -> {:noreply, stream_chunks(state)} end)

  def handle_info({:event, event}, state) do
    guard_connection(state, fn -> {:noreply, event(state, event)} end)
  end

  defp guard_connection(state, work) do
    work.()
  rescue
    _ ->
      Metrics.add(:malformed_connections)
      {:stop, :normal, state}
  catch
    {:disconnect, _reason, current} -> {:stop, :normal, current}
    {:disconnect, _reason} -> {:stop, :normal, state}
  end

  defp reset_window(state) do
    now = System.monotonic_time(:second)

    if now == state.window,
      do: state,
      else: %{state | window: now, packets: 0, bytes: 0, logical_bytes: 0}
  end

  defp consume(state, 0) do
    send(self(), :drain)
    {:noreply, state}
  end

  defp consume(state, remaining) do
    # Leave the exception boundary before recursing so the 64-packet drain does
    # not grow a stack of guards. A failed frame retains earlier accepted state.
    case guard_connection(state, fn -> consume_packet(state) end) do
      {:continue, next} -> consume(next, remaining - 1)
      result -> result
    end
  end

  defp consume_packet(state) do
    case Wire.next_frame(state.buffer, Valimc.config(:max_packet_bytes), state.threshold) do
      :more ->
        :ok = :inet.setopts(state.socket, active: :once)
        {:noreply, %{state | active: true}}

      {:error, _} ->
        reject(state, "Malformed packet")

      {:ok, id, payload, tail} ->
        state = reset_window(state)
        logical_bytes = state.logical_bytes + byte_size(payload)

        if logical_bytes > Valimc.config(:bytes_per_second),
          do: reject(state, "Decoded byte rate exceeded")

        state = %{state | logical_bytes: logical_bytes}

        if state.packets >= Valimc.config(:packets_per_second),
          do: reject(state, "Packet rate exceeded")

        Metrics.add(:packets_received)
        state = handle_packet(%{state | buffer: tail, packets: state.packets + 1}, id, payload)
        {:continue, state}
    end
  end

  defp handle_packet(%{phase: :handshake} = state, 0, payload) do
    {version, payload} = Wire.take_varint(payload)
    {_host, payload} = Wire.take_string(payload, 255)
    <<_port::16, payload::binary>> = payload
    {intent, <<>>} = Wire.take_varint(payload)

    case intent do
      1 ->
        %{state | phase: :status, protocol: version}

      2 ->
        state = %{state | phase: :login, protocol: version, step: :hello}

        if version != Valimc.protocol_version(),
          do: reject(state, "Use Minecraft Java #{Valimc.version()}")

        state

      _ ->
        reject(state, "Unsupported handshake intent")
    end
  end

  defp handle_packet(%{phase: :status} = state, 0, <<>>) do
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

  defp handle_packet(%{phase: :status} = state, 1, <<token::64>>) do
    send_packets(state, [Packets.packet("pong_response", <<token::64>>, :status)])
    throw({:disconnect, :status_complete})
  end

  defp handle_packet(%{phase: :login, step: :hello} = state, 0, payload) do
    {name, <<_provided_uuid::binary-size(16)>>} = Wire.take_string(payload, 16)

    if not Regex.match?(~r/\A[A-Za-z0-9_]{1,16}\z/, name),
      do: reject(state, "Invalid player name")

    player = %{
      pid: self(),
      name: name,
      uuid: offline_uuid(name),
      entity_id: System.unique_integer([:positive]),
      x: 0.5,
      y: 64.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      ready: false
    }

    case Players.join(player) do
      :ok -> :ok
      {:error, reason} -> reject(state, reason)
    end

    {store, player} =
      case PlayerStore.open(player.uuid) do
        {:ok, pid, pose} ->
          {pid, Map.merge(player, pose || %{})}

        {:error, reason} ->
          require Logger
          Logger.warning("Player pose load failed: #{inspect(reason)}")
          reject(state, "Player save unavailable; please retry after storage is repaired")
      end

    Players.update(self(), player)

    threshold = Valimc.config(:compression_threshold)

    if threshold != nil,
      do:
        send_packets(state, [Packets.packet("login_compression", Wire.varint(threshold), :login)])

    state = %{
      state
      | threshold: threshold,
        player: player,
        player_store: store,
        store_monitor: Process.monitor(store),
        step: :ack
    }

    send_packets(state, [
      Packets.packet(
        "login_finished",
        [player.uuid, Wire.string(name), <<0>>, :crypto.strong_rand_bytes(16)],
        :login
      )
    ])

    state
  end

  defp handle_packet(%{phase: :login, step: :ack} = state, 3, <<>>) do
    state = %{state | phase: :configuration, step: :known_packs}
    send_packets(state, [Packets.known_packs()])
    state
  end

  defp handle_packet(%{phase: :configuration} = state, id, payload) do
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
        enter_world(state)

      {name, _} when name in ["client_information", "custom_payload"] ->
        state

      _ ->
        reject(state, "Unexpected configuration packet")
    end
  end

  defp handle_packet(%{phase: :play} = state, id, payload) do
    case Data.name(:play, :serverbound, id) do
      "accept_teleportation" ->
        {id, <<x::float-64, y::float-64, z::float-64, _yaw::float-32, _pitch::float-32>>} =
          Wire.take_varint(payload)

        if id != state.teleport, do: reject(state, "Invalid teleport confirmation")

        if abs(x - state.player.x) + abs(y - state.player.y) + abs(z - state.player.z) > 0.01,
          do: reject(state, "Invalid teleport position")

        %{state | teleport_pending: false}

      "keep_alive" ->
        <<id::signed-64>> = payload

        case state.keepalive do
          {^id, _} -> %{state | keepalive: nil}
          _ -> reject(state, "Invalid keepalive")
        end

      "move_player_pos" ->
        <<x::float-64, y::float-64, z::float-64, _flags>> = payload
        move(state, %{x: x, y: y, z: z})

      "move_player_pos_rot" ->
        <<x::float-64, y::float-64, z::float-64, yaw::float-32, pitch::float-32, _flags>> =
          payload

        move(state, %{x: x, y: y, z: z, yaw: yaw, pitch: pitch})

      "move_player_rot" ->
        <<yaw::float-32, pitch::float-32, _flags>> = payload
        move(state, %{yaw: yaw, pitch: pitch})

      "chunk_batch_received" ->
        <<desired::float-32>> = payload
        if desired <= 0, do: reject(state, "Invalid chunk batch feedback")
        send(self(), :send_chunks)
        %{state | batch_pending: false}

      "player_action" ->
        break_block(state, payload)

      "set_carried_item" ->
        <<slot::signed-16>> = payload

        case Inventory.select(state.inventory, slot) do
          {:ok, inventory} ->
            send_packets(state, [Packets.held_slot(slot)])
            %{state | inventory: inventory}

          {:error, _} ->
            reject(state, "Invalid hotbar slot")
        end

      "set_creative_mode_slot" ->
        creative_slot(state, payload)

      "container_click" ->
        inventory_click(state, payload)

      "container_close" ->
        {_container, <<>>} = Wire.take_varint(payload)
        resync_inventory(state)

      "use_item_on" ->
        place_block(state, payload)

      "chat" ->
        {message, _metadata} = Wire.take_string(payload, 256)
        Players.broadcast({:chat, "<#{state.player.name}> #{message}"})
        state

      "chat_command" ->
        {command, <<>>} = Wire.take_string(payload, 256)
        command(state, command)

      nil ->
        reject(state, "Unknown packet ID")

      _known_but_unimplemented ->
        state
    end
  end

  defp handle_packet(state, _, _), do: reject(state, "Unexpected protocol state")

  defp enter_world(state) do
    state = %{state | phase: :play, step: nil, player: %{state.player | ready: true}}

    send_packets(state, [
      Packets.login(state.player),
      Packets.abilities(),
      Packets.health(),
      Packets.spawn_position(),
      Packets.commands(),
      Packets.inventory(state.inventory),
      Packets.held_slot(state.inventory.selected),
      Packets.teleport(state.player, state.teleport),
      Packets.packet("game_event", <<13, 0.0::float-32>>),
      Packets.player_info(state.player),
      Packets.chat(
        "Welcome to ValiMC. This is a creative protocol preview; survival is being built. /help"
      )
    ])

    existing = Players.ready(self())
    state = update_view(state)

    state =
      Enum.reduce(existing, state, fn player, acc -> event(acc, {:player_joined, player}) end)

    Process.send_after(self(), :publish_movement, 50)
    Process.send_after(self(), :save_player, Valimc.config(:player_save_interval_ms))
    state
  end

  defp move(%{teleport_pending: true} = state, _), do: state

  defp move(state, changes) do
    player = Map.merge(state.player, changes)
    if not PlayerStore.valid_pose?(player), do: reject(state, "Position outside world bounds")
    Players.update(self(), player)
    update_view(%{state | player: player})
  end

  defp update_view(state) do
    center = World.chunk_key(state.player.x, state.player.z)

    if center == state.center do
      state
    else
      {cx, cz} = center
      d = Valimc.config(:view_distance)
      desired = MapSet.new(for x <- (cx - d)..(cx + d), z <- (cz - d)..(cz + d), do: {x, z})

      send_packets(
        state,
        [Packets.center(center)] ++
          Enum.map(MapSet.difference(state.chunks, desired), &Packets.unload/1)
      )

      regions = MapSet.new(desired, &World.region_key/1)
      World.subscribe(regions, state.regions)

      pending =
        MapSet.difference(desired, state.chunks)
        |> Enum.sort_by(fn {x, z} -> abs(x - cx) + abs(z - cz) end)

      send(self(), :send_chunks)

      state = %{
        state
        | center: center,
          regions: regions,
          chunks: MapSet.intersection(state.chunks, desired),
          pending: pending
      }

      state
    end
  end

  defp stream_chunks(%{phase: :play, batch_pending: false, pending: [_ | _]} = state) do
    {batch, pending} = Enum.split(state.pending, 4)

    frames =
      [Packets.frame(Packets.packet("chunk_batch_start", <<>>), state.threshold)] ++
        Enum.map(batch, &World.chunk/1) ++
        [
          Packets.frame(
            Packets.packet("chunk_batch_finished", Wire.varint(length(batch))),
            state.threshold
          )
        ]

    send_frames(state, frames)

    %{
      state
      | pending: pending,
        chunks: Enum.reduce(batch, state.chunks, &MapSet.put(&2, &1)),
        batch_pending: true
    }
  end

  defp stream_chunks(state), do: state

  defp visible?(state, player) do
    {cx, cz} = World.chunk_key(state.player.x, state.player.z)
    {px, pz} = World.chunk_key(player.x, player.z)
    d = Valimc.config(:view_distance)
    player.pid != self() and abs(cx - px) <= d and abs(cz - pz) <= d
  end

  defp event(%{phase: :play} = state, {:chat, message}) do
    send_packets(state, [Packets.chat(message)])
    state
  end

  defp event(%{phase: :play} = state, {:block, {x, _, z} = pos, block}) do
    if MapSet.member?(state.chunks, World.chunk_key(x, z)),
      do: send_packets(state, [Packets.block(pos, block)])

    state
  end

  defp event(%{phase: :play} = state, {:player_joined, player}), do: track_peer(state, player)

  defp event(%{phase: :play} = state, {:player_left, player}) do
    if Map.has_key?(state.peers, player.pid),
      do: send_packets(state, [Packets.remove_entity(player), Packets.remove_info(player)])

    %{state | peers: Map.delete(state.peers, player.pid)}
  end

  defp event(state, _), do: state

  defp track_peer(state, player, mode \\ :direct) do
    cond do
      player.pid == self() or not Process.alive?(player.pid) ->
        state

      visible?(state, player) ->
        view = Packets.view(player)

        packets =
          case state.peers[player.pid] do
            nil -> [Packets.player_info(player), Packets.add_entity(player)]
            ^view -> []
            previous -> List.wrap(Packets.move_entity(player, previous))
          end

        if packets == [] do
          state
        else
          state = emit_peer_packets(state, packets, mode)
          %{state | peers: Map.put(state.peers, player.pid, view)}
        end

      Map.has_key?(state.peers, player.pid) ->
        state =
          emit_peer_packets(
            state,
            [Packets.remove_entity(player), Packets.remove_info(player)],
            mode
          )

        %{state | peers: Map.delete(state.peers, player.pid)}

      true ->
        state
    end
  end

  defp emit_peer_packets(state, packets, :direct) do
    send_packets(state, packets)
    state
  end

  defp emit_peer_packets(state, packets, :buffer),
    do: %{state | outbound: [packets | state.outbound]}

  defp reachable?(state, {x, y, z}) do
    p = state.player

    World.Chunk.valid_y?(y) and
      (x + 0.5 - p.x) ** 2 + (y + 0.5 - (p.y + 1.62)) ** 2 + (z + 0.5 - p.z) ** 2 <= 36
  end

  defp break_block(state, payload) do
    {action, payload} = Wire.take_varint(payload)
    {position, <<_face, payload::binary>>} = Wire.take_position(payload)
    {sequence, <<>>} = Wire.take_varint(payload)

    if action == ItemTypes.action_id("swap_item_with_offhand") do
      inventory = Inventory.swap_hands(state.inventory)

      send_packets(state, [
        Packets.container_slot(
          inventory.state_id,
          36 + inventory.selected,
          Inventory.held(inventory, :main)
        ),
        Packets.container_slot(inventory.state_id, 45, Inventory.held(inventory, :off))
      ])

      %{state | inventory: inventory}
    else
      break_block_action(state, action, position, sequence)
    end
  end

  defp break_block_action(state, action, position, sequence) do
    if action in [
         ItemTypes.action_id("start_destroy_block"),
         ItemTypes.action_id("stop_destroy_block")
       ] and reachable?(state, position), do: World.set_block(position, 0)

    updates =
      if reachable?(state, position),
        do: [Packets.block(position, World.get_block(position))],
        else: []

    send_packets(state, [Packets.ack(sequence) | updates])

    state
  end

  defp creative_slot(state, <<slot::signed-16, payload::binary>>) do
    case ItemStack.decode(payload, :untrusted) do
      {:ok, stack} ->
        case Inventory.creative(state.inventory, slot, stack) do
          {:ok, inventory} ->
            send_packets(state, [
              Packets.container_slot(inventory.state_id, slot, Inventory.get(inventory, slot))
            ])

            %{state | inventory: inventory}

          {:error, _} ->
            send_packets(state, [Packets.chat("Creative slot is unavailable; inventory restored")])

            resync_inventory(state)
        end

      {:unsupported, _names} ->
        send_packets(state, [
          Packets.chat("This item's components are not supported yet; slot restored")
        ])

        if slot in 1..45, do: correct_creative_slot(state, slot), else: resync_inventory(state)

      {:error, _} ->
        reject(state, "Malformed or invalid creative item")
    end
  end

  defp correct_creative_slot(state, slot) do
    inventory = state.inventory |> Inventory.cancel_drag() |> Inventory.advance()

    send_packets(state, [
      Packets.container_slot(inventory.state_id, slot, Inventory.get(inventory, slot))
    ])

    %{state | inventory: inventory}
  end

  defp resync_inventory(state) do
    inventory = state.inventory |> Inventory.cancel_drag() |> Inventory.advance()
    send_packets(state, [Packets.inventory(inventory), Packets.cursor(inventory.carried)])
    %{state | inventory: inventory}
  end

  defp inventory_click(state, payload) do
    case InventoryClick.decode(payload) do
      {:ok, %{container: 0} = click} ->
        # The vanilla listener applies actions to current owner state even when
        # the reported state ID is stale. Predictions only guide replication.
        case Inventory.click(state.inventory, click.action, click.slot, click.button) do
          {:ok, inventory} ->
            send_packets(state, [Packets.inventory(inventory), Packets.cursor(inventory.carried)])
            %{state | inventory: inventory}

          {:error, _} ->
            send_packets(state, [
              Packets.chat("This inventory operation is not supported yet; state restored")
            ])

            resync_inventory(state)
        end

      {:ok, click} ->
        send_packets(state, [Packets.packet("container_close", Wire.varint(click.container))])
        resync_inventory(state)

      {:error, _} ->
        reject(state, "Malformed inventory click")
    end
  end

  defp place_block(state, payload) do
    {hand, payload} = Wire.take_varint(payload)
    {position, payload} = Wire.take_position(payload)

    {face, <<_cursor::binary-size(12), _inside, _border, payload::binary>>} =
      Wire.take_varint(payload)

    {sequence, <<>>} = Wire.take_varint(payload)
    {x, y, z} = position

    target =
      case face do
        0 -> {x, y - 1, z}
        1 -> {x, y + 1, z}
        2 -> {x, y, z - 1}
        3 -> {x, y, z + 1}
        4 -> {x - 1, y, z}
        5 -> {x + 1, y, z}
        _ -> reject(state, "Invalid block face")
      end

    stack =
      case hand do
        0 -> Inventory.held(state.inventory, :main)
        1 -> Inventory.held(state.inventory, :off)
        _ -> reject(state, "Invalid interaction hand")
      end

    item = if stack, do: Data.item_block(stack.item_id)
    if item != nil and reachable?(state, target), do: World.set_block(target, item)

    updates =
      if reachable?(state, target), do: [Packets.block(target, World.get_block(target))], else: []

    send_packets(state, [Packets.ack(sequence) | updates])
    state
  end

  defp command(state, input), do: execute_command(state, Valimc.Commands.resolve(input))

  defp execute_command(state, :help) do
    send_packets(state, [
      Packets.chat(Valimc.Commands.help_text())
    ])

    state
  end

  defp execute_command(state, :stats) do
    stats = Metrics.snapshot()

    send_packets(state, [
      Packets.chat(
        "#{stats.players} players · #{stats.regions} regions · #{stats.schedulers} schedulers · #{div(stats.memory_bytes, 1_048_576)} MiB"
      )
    ])

    state
  end

  defp execute_command(state, :spawn) do
    player = %{state.player | x: 0.5, y: 64.0, z: 0.5}
    teleport = state.teleport + 1
    send_packets(state, [Packets.teleport(player, teleport)])
    Players.update(self(), player)

    update_view(%{
      state
      | player: player,
        teleport: teleport,
        teleport_pending: true
    })
  end

  defp execute_command(state, :unknown) do
    send_packets(state, [Packets.chat("Unknown command. Use /help.")])
    state
  end

  defp send_packets(state, packets),
    do: send_frames(state, Enum.map(packets, &Packets.frame(&1, state.threshold)))

  defp send_frames(_state, []), do: :ok

  defp send_frames(state, frames) do
    case :gen_tcp.send(state.socket, frames) do
      :ok ->
        Metrics.add(:bytes_sent, IO.iodata_length(frames))
        Metrics.add(:packets_sent, length(frames))
        :ok

      {:error, reason} ->
        throw({:disconnect, reason, state})
    end
  end

  defp reject(state, message) do
    Metrics.add(:connections_rejected)
    if state.phase in [:handshake, :status], do: throw({:disconnect, message, state})

    payload =
      if state.phase == :login,
        do: Wire.string(IO.iodata_to_binary(:json.encode(%{text: message}))),
        else: Wire.text_component(message)

    phase = if state.phase in [:login, :configuration, :play], do: state.phase, else: :login
    name = if phase == :login, do: "login_disconnect", else: "disconnect"

    :gen_tcp.send(
      state.socket,
      Packets.packet(name, payload, phase) |> Packets.frame(state.threshold)
    )

    throw({:disconnect, message, state})
  end

  def offline_uuid(name) do
    <<a::48, b::16, c::16, d::48>> = :crypto.hash(:md5, "OfflinePlayer:" <> name)
    <<a::48, (b &&& 0x0FFF) ||| 0x3000::16, (c &&& 0x3FFF) ||| 0x8000::16, d::48>>
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)

    if state.player_store && state.phase == :play do
      # Read the latest owner publication for movement accepted before a failure.
      player =
        case Players.get(self()) do
          {:ok, latest} -> latest
          :error -> state.player
        end

      try do
        PlayerStore.close(state.player_store, player)
      catch
        :exit, _ ->
          require Logger
          Logger.error("Player pose final save could not complete")
      end
    end
  end
end
