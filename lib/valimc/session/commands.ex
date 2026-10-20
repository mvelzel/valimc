defmodule Valimc.Session.Commands do
  @moduledoc "Chat throttling and chat command dispatch (VMC-069, VMC-053)."

  import Valimc.Net.Codec, only: [reject: 2]
  alias Valimc.ChatThrottle

  def throttle_chat(state) do
    case ChatThrottle.record(state.chat_throttle) do
      {:ok, throttle} -> %{state | chat_throttle: throttle}
      {:spam, _} -> reject(state, "Kicked for spamming")
    end
  end

  def command(state, input), do: Valimc.Commands.execute(state, input)
end
