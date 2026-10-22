defmodule Valimc.Net.Messages do
  @moduledoc """
  The connection's own messages (VMC-069, VMC-077i3): socket data and the
  read loop, the login jobs' replies and deadlines, the login deadline,
  keepalives, chunk replies and the chunk stream, and linked exits. Before
  play the connection runs this router on its whole state, after its
  session's jobs (`dispatch/2`), and hands anything else to the session's
  router (`Valimc.Session.Messages`); in play its link uses `info/2` for the
  connection's part (`Valimc.Net.Link`).
  """
  alias Valimc.Data.Metrics
  alias Valimc.Net.LoginFlow
  alias Valimc.Protocol.{Encryption, Packets}
  alias Valimc.Session.{Messages, Replication}
  alias Valimc.World.ChestLidReplication

  import Valimc.Protocol.Codec,
    only: [send_packets: 2, crypt_bytes: 3, reject: 2, reset_window: 1]

  @doc "A message to a connection that holds its session (before play)."
  def dispatch(message, state), do: Messages.dispatch(message, state, &info/2)

  def info(:activate, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    Process.send_after(self(), :login_deadline, Valimc.config(:login_timeout_ms))
    Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))
    Metrics.add(:connections_accepted)
    {:noreply, %{state | active: true}}
  end

  def info({:tcp, socket, data}, %{socket: socket} = state) do
    Messages.guard(state, fn ->
      state = reset_window(state)
      bytes = state.bytes + byte_size(data)
      if bytes > Valimc.config(:bytes_per_second), do: reject(state, "Inbound byte rate exceeded")

      if byte_size(state.buffer) + byte_size(data) > Valimc.Net.Connection.frame_limit(state) + 5,
        do: reject(state, "Receive buffer exceeded")

      data = crypt_bytes(state.cipher, :decrypt, data)

      Valimc.Net.Connection.consume(
        %{state | buffer: state.buffer <> data, bytes: bytes, active: false},
        64
      )
    end)
  end

  def info(:drain, state),
    do:
      Messages.guard(state, fn ->
        Valimc.Net.Connection.consume(state, 64)
      end)

  def info({:tcp_closed, _}, state), do: {:stop, :normal, state}

  def info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  def info(
        {:key_verified, worker, token, result},
        %{key_job: %{pid: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    Valimc.Net.LoginJobs.cancel(job)
    state = %{state | key_job: nil}

    Messages.guard(state, fn ->
      if System.monotonic_time(:millisecond) >= job.deadline,
        do: reject(state, "Login encryption timed out")

      case result do
        {:ok, secret} ->
          {:ok, cipher} = Encryption.new(secret)
          # This tail followed the plaintext key frame and has never been decrypted.
          state = %{
            state
            | cipher: cipher,
              buffer: crypt_bytes(cipher, :decrypt, state.buffer),
              step: nil
          }

          if state.online_mode do
            digest = Encryption.server_hash(secret, state.key_public)
            token = make_ref()

            case Valimc.Net.LoginJobs.session(self(), token, state.login_name, digest) do
              {:ok, job} ->
                timeout = max(job.deadline - System.monotonic_time(:millisecond), 0)
                timer = Process.send_after(self(), {:session_deadline, token}, timeout)
                Valimc.Net.LoginJobs.activate(job)

                {:noreply,
                 %{
                   state
                   | step: :auth_job,
                     auth_job: Map.put(job, :timer, timer),
                     key_public: nil
                 }}

              _ ->
                reject(state, "Authentication busy; please retry")
            end
          else
            state = LoginFlow.start_player_login(%{state | key_public: nil}, state.login_name)
            Valimc.Net.Connection.consume(state, 64)
          end

        _ ->
          reject(state, "Invalid login encryption response")
      end
    end)
  end

  def info({:key_verified, _, _, _}, state), do: {:noreply, state}

  def info(
        {:session_verified, worker, token, result},
        %{auth_job: %{pid: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    Valimc.Net.LoginJobs.cancel(job)
    state = %{state | auth_job: nil}

    Messages.guard(state, fn ->
      if System.monotonic_time(:millisecond) >= job.deadline,
        do: reject(state, "Authentication timed out")

      case result do
        {:ok, profile} ->
          if not Valimc.Net.Auth.Profile.valid?(profile, state.login_name),
            do: reject(state, "Invalid authentication profile")

          state = LoginFlow.start_player_login(%{state | step: nil}, state.login_name, profile)
          Valimc.Net.Connection.consume(state, 64)

        {:error, :unverified_session} ->
          reject(state, "Failed to verify username")

        _ ->
          reject(state, "Authentication servers unavailable; please retry")
      end
    end)
  end

  def info({:session_verified, _, _, _}, state), do: {:noreply, state}

  def info({:session_deadline, token}, %{auth_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do:
        Messages.guard(state, fn ->
          reject(state, "Authentication timed out")
        end),
      else: {:noreply, state}
  end

  def info({:session_deadline, _}, state), do: {:noreply, state}

  def info({:DOWN, ref, :process, _, _}, %{auth_job: %{monitor: ref}} = state),
    do:
      Messages.guard(state, fn ->
        reject(state, "Authentication servers unavailable; please retry")
      end)

  def info({:key_deadline, token}, %{key_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do:
        Messages.guard(state, fn ->
          reject(state, "Login encryption timed out")
        end),
      else: {:noreply, state}
  end

  def info({:key_deadline, _}, state), do: {:noreply, state}

  def info({:DOWN, ref, :process, _, _}, %{key_job: %{monitor: ref}} = state),
    do:
      Messages.guard(state, fn ->
        reject(state, "Login encryption unavailable")
      end)

  def info({:DOWN, ref, :process, pid, _} = message, %{socket: socket} = state)
      when socket != nil do
    case Replication.chunk_reply(state, message) do
      {:ok, state} -> {:noreply, state}
      :error -> down(state, ref, pid)
    end
  end

  # Replies to chunk requests (VMC-077e) are tagged with the request's alias.
  def info({[:alias | ref], _} = message, state) when is_reference(ref) do
    Messages.guard(state, fn ->
      case Replication.chunk_reply(state, message) do
        {:ok, state} -> {:noreply, state}
        :error -> {:noreply, state}
      end
    end)
  end

  def info(:login_deadline, %{phase: :play} = state), do: {:noreply, state}

  def info(:login_deadline, state), do: {:stop, :normal, state}

  def info(:keepalive, state) do
    Messages.guard(state, fn ->
      Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))

      if state.phase == :play do
        now = System.monotonic_time(:millisecond)
        timeout = Valimc.config(:keepalive_timeout_ms)

        idle = Valimc.World.Settings.get(:idle_timeout)

        case state.keepalive do
          {_, sent} when now - sent > timeout ->
            reject(state, "Keepalive timed out")

          # VMC-010c: the idle kick, checked with each keepalive (a hosted
          # session checks it on its own tick).
          _
          when idle > 0 and is_map_key(state, :last_action) and
                 now - state.last_action > idle * 60_000 ->
            reject(
              state,
              Valimc.Text.encode(Valimc.Text.translatable("multiplayer.disconnect.idling"))
            )

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

  def info(:send_chunks, state),
    do:
      Messages.guard(state, fn ->
        {:noreply, Replication.stream_chunks(state)}
      end)

  # Overload is signalled, not killed, so terminate/2 still saves and releases jobs.
  def info({:EXIT, _from, {:shutdown, :overloaded} = reason}, state),
    do: {:stop, reason, state}

  def info({:EXIT, _from, :normal}, state), do: {:noreply, state}

  def info({:EXIT, _from, reason}, state),
    do: {:stop, {:shutdown, {:linked_exit, reason}}, state}

  def info(message, state), do: Messages.info(message, state)

  defp down(state, ref, pid) do
    {lids, closed} = ChestLidReplication.down(state.chest_lids, ref, pid)
    send_packets(state, Enum.map(closed, &Packets.chest_lid(&1, false)))
    state = %{state | chest_lids: lids}

    {:noreply, Messages.forget_pose_source(state, ref)}
  end
end
