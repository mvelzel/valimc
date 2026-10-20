defmodule Valimc.Net.Codec do
  @moduledoc """
  Connection wire I/O (VMC-069): framing, the session cipher, bounded socket
  writes, inbound rate windows and protocol-correct rejection. Connection state
  is passed in; nothing here owns a process.
  """
  alias Valimc.Metrics
  alias Valimc.Protocol.{Encryption, Packets, Wire}

  def send_packets(state, packets),
    do: send_frames(state, Enum.map(packets, &Packets.frame(&1, state.threshold)))

  def send_frames(_state, []), do: :ok

  def send_frames(state, frames) do
    size = IO.iodata_length(frames)

    if size > Valimc.config(:max_write_batch_bytes),
      do: throw({:disconnect, :write_batch_too_large, state})

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
    if state.phase in [:handshake, :status], do: throw({:disconnect, message, state})

    payload =
      if state.phase == :login,
        do: Wire.string(IO.iodata_to_binary(:json.encode(%{text: message}))),
        else: Wire.text_component(message)

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
