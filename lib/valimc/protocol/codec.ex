defmodule Valimc.Protocol.Codec do
  @moduledoc """
  Connection wire I/O (VMC-069): framing, the session cipher, bounded socket
  writes, inbound rate windows and protocol-correct rejection. Connection state
  is passed in; nothing here owns a process.
  """
  alias Valimc.Data.Metrics
  alias Valimc.Protocol.{Encryption, Packets, Wire}

  # A session its group hosts (VMC-077i3) has no socket: its client output
  # (frames and view changes) queues here during the group's callback, which
  # forwards it to the connection in order (`Valimc.Player.Host`).
  @outbox {__MODULE__, :outbox}
  # Why this connection ends, for its leave message (`Valimc.Player.Presence`).
  @reason {__MODULE__, :reason}

  @doc "Start queueing a hosted session's client output."
  def open_outbox, do: Process.put(@outbox, [])

  @doc "The queued output, newest first, or nil; the queue closes."
  def take_outbox, do: Process.delete(@outbox)

  @doc "Queue `item` (`{:frames, iodata}`, `{:view, map}`, `{:reset, map}`) for the connection."
  def out(item) do
    case Process.get(@outbox) do
      nil -> raise ArgumentError, "session output outside a hosted callback"
      items -> Process.put(@outbox, [item | items])
    end

    :ok
  end

  @doc "Remembers why this connection ends (a text or a server text component)."
  def record_reason(reason), do: Process.put(@reason, reason)

  def reason, do: Process.get(@reason)

  @doc "The recorded reason, forgotten here: a session's group passes it to the connection."
  def take_reason, do: Process.delete(@reason)

  def send_packets(state, packets),
    do: send_frames(state, Enum.map(packets, &Packets.frame(&1, state.threshold)))

  def send_frames(_state, []), do: :ok

  def send_frames(state, frames) do
    size = IO.iodata_length(frames)

    if size > Valimc.config(:max_write_batch_bytes),
      do: throw({:disconnect, :write_batch_too_large, state})

    write(state, frames, size)
  end

  defp write(%{socket: nil}, frames, _size), do: out({:frames, frames})

  defp write(state, frames, size) do
    bytes =
      if state.cipher,
        do: crypt_bytes(state.cipher, :encrypt, IO.iodata_to_binary(frames)),
        else: frames

    case :gen_tcp.send(state.socket, bytes) do
      :ok ->
        Metrics.add(:bytes_sent, size)
        Metrics.add(:packets_sent, length(frames))
        :ok

      {:error, reason} ->
        throw({:disconnect, reason, state})
    end
  end

  def crypt_bytes(nil, _, bytes), do: bytes

  def crypt_bytes(cipher, direction, bytes) do
    size = Encryption.max_chunk()

    chunks =
      Stream.unfold(bytes, fn
        <<>> ->
          nil

        remaining ->
          count = min(byte_size(remaining), size)
          <<part::binary-size(^count), tail::binary>> = remaining
          {part, tail}
      end)

    chunks
    |> Enum.map(fn chunk ->
      {:ok, transformed} = apply(Encryption, direction, [cipher, chunk])
      transformed
    end)
    |> IO.iodata_to_binary()
  end

  def reject(state, message) do
    Metrics.add(:connections_rejected)
    record_reason(message)
    if state.phase in [:handshake, :status], do: throw({:disconnect, message, state})

    payload =
      case {state.phase, message} do
        {:login, %Valimc.Protocol.ServerText{tag: tag}} ->
          Wire.string(IO.iodata_to_binary(:json.encode(Valimc.Text.to_json(tag))))

        {:login, text} ->
          Wire.string(IO.iodata_to_binary(:json.encode(%{text: text})))

        _ ->
          Wire.text_component(message)
      end

    phase = if state.phase in [:login, :configuration, :play], do: state.phase, else: :login
    name = if phase == :login, do: "login_disconnect", else: "disconnect"

    send_packets(state, [Packets.packet(name, payload, phase)])

    throw({:disconnect, message, state})
  end

  def reset_window(state) do
    now = System.monotonic_time(:second)

    if now == state.window,
      do: state,
      else: %{state | window: now, packets: 0, bytes: 0, logical_bytes: 0}
  end
end
