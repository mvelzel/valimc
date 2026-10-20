defmodule Valimc.TableAccess do
  @moduledoc "One expiring player grant checked against the current authoritative table block."
  alias Valimc.{PlayerInteraction, Protocol.Data}
  @table Data.item_block(Data.item("crafting_table"))
  @modes [:survival, :creative, :adventure, :spectator]

  defdelegate opens?(mode, hand, secondary, main, off),
    to: PlayerInteraction,
    as: :opens_block_menu?

  def valid?(block, mode, eye, position),
    do: block == @table and PlayerInteraction.within_block?(mode, eye, position, 4.0)

  def authorize(
        block,
        position,
        %{
          kind: kind,
          mode: mode,
          eye: {x, y, z},
          expires: expires,
          hand: hand,
          secondary: secondary,
          main: main,
          off: off
        } = grant,
        now
      )
      when kind in [:open, :click, :check] and mode in @modes and is_number(x) and
             is_number(y) and is_number(z) and is_integer(expires) and hand in [:main, :off] and
             is_boolean(secondary) and is_boolean(main) and is_boolean(off) do
    cond do
      now >= expires ->
        {:error, :expired_table_grant}

      kind == :open ->
        if block == @table and
             PlayerInteraction.within_block?(mode, grant.eye, position) and
             opens?(mode, grant.hand, grant.secondary, grant.main, grant.off),
           do: :open,
           else: :pass

      valid?(block, mode, grant.eye, position) ->
        :valid

      true ->
        {:error, :invalid_table_context}
    end
  end

  def authorize(_, _, _, _), do: {:error, :invalid_table_grant}

  @doc """
  An opening use of a block whose interaction ValiMC cannot perform is refused;
  a use vanilla would not send to the block (secondary use with an item) passes
  on to placement.
  """
  def refuse_use(_block, position, %{kind: :open, mode: mode, expires: expires} = grant, now)
      when mode in @modes and is_integer(expires) do
    cond do
      now >= expires ->
        {:error, :expired_table_grant}

      PlayerInteraction.within_block?(mode, grant.eye, position) and
          opens?(mode, grant.hand, grant.secondary, grant.main, grant.off) ->
        {:error, :unsupported_block_entity}

      true ->
        :pass
    end
  end

  def refuse_use(block, position, grant, now), do: authorize(block, position, grant, now)
end
