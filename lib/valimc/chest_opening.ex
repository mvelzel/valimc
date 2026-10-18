defmodule Valimc.ChestOpening do
  @moduledoc "Pinned single-chest providers and fresh view admission; locks/loot are separate."
  import Bitwise
  alias Valimc.{ChestAccess, PlayerInteraction}
  @path Path.expand("../../priv/protocol/chest_opening.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count @facts["state_count"]
  @mask Base.decode64!(@facts["blocked_above_bits"])
  if @count != Valimc.Protocol.Data.block_state_count() or byte_size(@mask) != div(@count + 7, 8),
    do: raise("Wrong chest opening facts")

  def obstructed?(above, false) when is_integer(above) and above >= 0 and above < @count,
    do: (:binary.at(@mask, above >>> 3) &&& 1 <<< (above &&& 7)) != 0

  def obstructed?(_, _), do: true

  def provider?(block, true, above, sitting_cat) when is_boolean(sitting_cat),
    do: ChestAccess.single?(block) and not obstructed?(above, sitting_cat)

  def provider?(_, _, _, _), do: false

  def authorize(block, entry, above, position, grant, now)
      when is_map(grant) and is_integer(now) do
    with %{
           kind: kind,
           mode: mode,
           eye: {x, y, z},
           expires: expires,
           hand: hand,
           secondary: secondary,
           main: main,
           off: off
         } <- grant,
         true <-
           kind in [:open, :check, :click, :refresh] and
             mode in [:survival, :creative, :adventure, :spectator],
         true <- is_number(x) and is_number(y) and is_number(z) and is_integer(expires),
         true <-
           hand in [:main, :off] and is_boolean(secondary) and
             is_boolean(main) and is_boolean(off) do
      cond do
        expires <= now or expires > now + 250 ->
          {:error, :expired_chest_grant}

        kind == :open and
            not PlayerInteraction.opens_block_menu?(mode, hand, secondary, main, off) ->
          :pass

        not match?(%{rows: 3, slots: slots} when tuple_size(slots) == 27, entry) ->
          {:error, :missing_chest}

        kind == :open and not PlayerInteraction.within_block?(mode, grant.eye, position) ->
          {:error, :invalid_chest_context}

        kind == :open and not provider?(block, true, above, false) ->
          {:error, :blocked_chest}

        not ChestAccess.valid_view?(block, mode, grant.eye, position) ->
          {:error, :invalid_chest_context}

        kind != :open and grant[:menu] != :chest ->
          {:error, :invalid_chest_context}

        kind in [:check, :click] and grant[:revision] == entry.revision ->
          :valid

        true ->
          {:chest, block, entry}
      end
    else
      _ -> {:error, :invalid_chest_grant}
    end
  end

  def authorize(_, _, _, _, _, _), do: {:error, :invalid_chest_grant}
end
