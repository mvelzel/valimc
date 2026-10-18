defmodule Valimc.ChestAccess do
  @moduledoc "Single ordinary chest identity and action access; opening obstruction is a separate check."
  alias Valimc.PlayerInteraction
  @path Path.expand("../../priv/protocol/chest_states.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @single MapSet.new(@facts["single_states"])
  @ordinary MapSet.new(@facts["states"], & &1["state"])
  @modes [:survival, :creative, :adventure, :spectator]

  def ordinary?(block), do: MapSet.member?(@ordinary, block)

  def single?(block), do: MapSet.member?(@single, block)

  def valid_view?(block, mode, {x, y, z} = eye, position)
      when mode in @modes and is_number(x) and is_number(y) and is_number(z),
      do: single?(block) and PlayerInteraction.within_block?(mode, eye, position, 4.0)

  def valid_view?(_, _, _, _), do: false

  def authorize(
        block,
        position,
        %{mode: mode, eye: eye, health: hp, expires: expires},
        now
      )
      when mode in [:survival, :creative, :adventure] and is_number(hp) and hp > 0 and
             is_integer(expires) and is_integer(now) do
    cond do
      expires <= now or expires > now + 250 -> {:error, :expired_container_context}
      valid_view?(block, mode, eye, position) -> :ok
      true -> {:error, :invalid_container_context}
    end
  end

  def authorize(_, _, _, _), do: {:error, :invalid_container_context}
end
