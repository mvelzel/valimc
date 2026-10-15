defmodule Valimc.PlayerInput do
  @moduledoc "Connection-owned native input intent and shared Shift/sprint flags, not a selected pose."
  import Bitwise
  alias Valimc.Protocol.Wire

  defstruct buttons: 0, shared_flags: 0, load_ticks: 60

  @actions {:stop_sleeping, :start_sprinting, :stop_sprinting, :start_riding_jump,
            :stop_riding_jump, :open_inventory, :start_fall_flying}
  @buttons %{forward: 1, backward: 2, left: 4, right: 8, jump: 16, shift: 32, sprint: 64}

  def pressed?(%__MODULE__{buttons: buttons}, key),
    do: (buttons &&& Map.fetch!(@buttons, key)) != 0

  def loaded?(%__MODULE__{load_ticks: ticks}), do: ticks == 0
  def loaded(%__MODULE__{} = input), do: %{input | load_ticks: 0}
  def tick(%__MODULE__{} = input), do: %{input | load_ticks: max(0, input.load_ticks - 1)}

  @doc "Native world-space reported intent; this observation does not authorize displacement."
  def move_intent(%__MODULE__{buttons: buttons}, yaw) when buttons in 0..127 do
    x = flag(buttons, 4) - flag(buttons, 8)
    z = flag(buttons, 1) - flag(buttons, 2)
    Valimc.Physics.RelativeMotion.vector({x, 0.0, z}, 1.0, yaw)
  end

  def move_intent(_, _), do: {:error, :invalid_relative_motion}

  def decode(<<buttons>>), do: {:ok, buttons &&& 127}
  def decode(_), do: {:error, :invalid_player_input}

  def decode_command(payload) when is_binary(payload) and byte_size(payload) <= 15 do
    with {:ok, id, rest} <- Wire.read_varint(payload),
         {:ok, action, rest} when action in 0..6 <- Wire.read_varint(rest),
         {:ok, data, <<>>} <- Wire.read_varint(rest) do
      {:ok, {signed(id), elem(@actions, action), signed(data)}}
    else
      _ -> {:error, :invalid_player_command}
    end
  end

  def decode_command(_), do: {:error, :invalid_player_command}

  def receive_input(%__MODULE__{} = input, payload) do
    with {:ok, buttons} <- decode(payload) do
      # Vanilla retains pre-load intent without changing shared flags or replaying it on load.
      flags =
        if loaded?(input),
          do: set_flag(input.shared_flags, 2, (buttons &&& 32) != 0),
          else: input.shared_flags

      {:ok, %{input | buttons: buttons, shared_flags: flags}}
    end
  end

  def receive_command(%__MODULE__{} = input, payload) do
    with {:ok, {_entity_id, action, _data}} <- decode_command(payload) do
      flags =
        case {loaded?(input), action} do
          {true, :start_sprinting} -> set_flag(input.shared_flags, 8, true)
          {true, :stop_sprinting} -> set_flag(input.shared_flags, 8, false)
          _ -> input.shared_flags
        end

      # The command affects its sender; vanilla does not use its entity-ID field here.
      {:ok, %{input | shared_flags: flags}}
    end
  end

  defp set_flag(flags, bit, true), do: flags ||| bit
  defp set_flag(flags, bit, false), do: flags &&& bnot(bit)
  defp signed(value) when value >= 0x80000000, do: value - 0x100000000
  defp signed(value), do: value
  defp flag(buttons, bit), do: if((buttons &&& bit) != 0, do: 1, else: 0)
end
