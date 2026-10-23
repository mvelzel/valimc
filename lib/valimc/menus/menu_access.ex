defmodule Valimc.Menus.MenuAccess do
  @moduledoc """
  The one access check for block menus (VMC-077i2): a chest, a furnace-family
  block, a hopper, a dropper or dispenser (VMC-049a) or a crafting table, opened and used under an expiring grant the
  player's connection makes and the block's owner checks against the block,
  its owned entry and the player's reach, as vanilla checks a menu's use and
  its `stillValid`.

  A grant is `%{kind, mode, eye, expires, hand, secondary, main, off}` plus,
  after opening, the `menu` it names and the entry `revision` it saw. Kinds:
  `:open`, and for an open menu `:check`, `:click`, and for containers also
  `:subscribe` and `:refresh`.

  A chest opens only when nothing solid sits on it (`provider?/4`, vanilla's
  `ChestBlock.isChestBlockedAt` from the generated opening facts).
  """
  import Bitwise
  alias Valimc.Blocks.{Cooking, CookingBlocks}
  alias Valimc.Living.Interaction
  alias Valimc.Blocks.{Chest, Machine}
  alias Valimc.Protocol.Data
  use Valimc.Data.Facts, "protocol/chest_opening.json"

  @count @facts["state_count"]
  @mask Base.decode64!(@facts["blocked_above_bits"])
  unless @count == Data.block_state_count() and byte_size(@mask) == div(@count + 7, 8),
    do: raise("Wrong chest opening facts")

  @table Data.item_block(Data.item("crafting_table"))
  @modes [:survival, :creative, :adventure, :spectator]
  @kinds %{
    chest: [:open, :subscribe, :check, :click, :refresh],
    cooking: [:open, :subscribe, :check, :click, :refresh],
    hopper: [:open, :subscribe, :check, :click, :refresh],
    dispenser: [:open, :subscribe, :check, :click, :refresh],
    table: [:open, :click, :check]
  }

  @doc "The menus over an owned container entry."
  def containers, do: [:chest, :cooking, :hopper, :dispenser]

  @doc "The menu a block opens: `:chest`, `:cooking`, `:hopper`, `:dispenser` (droppers too), `:table` or nil."
  def menu(nil), do: nil

  def menu(block) do
    cond do
      Chest.ordinary?(block) -> :chest
      CookingBlocks.kind(block) != nil -> :cooking
      Machine.kind(block) == :hopper -> :hopper
      Machine.kind(block) != nil -> :dispenser
      block == @table -> :table
      true -> nil
    end
  end

  @doc "Whether a player in `mode` at `eye` still reaches `menu`'s block at `position`."
  def valid_view?(menu, block, mode, {x, y, z} = eye, position)
      when mode in @modes and is_number(x) and is_number(y) and is_number(z),
      do: menu(block) == menu and Interaction.within_block?(mode, eye, position, 4.0)

  def valid_view?(_, _, _, _, _), do: false

  @doc """
  A container action's access (a chest's or a furnace's): a live player in a
  playing mode, a fresh grant and the block in reach.
  """
  def authorize_action(
        menu,
        block,
        position,
        %{mode: mode, eye: eye, health: hp, expires: expires},
        now
      )
      when mode in [:survival, :creative, :adventure] and is_number(hp) and hp > 0 and
             is_integer(expires) and is_integer(now) do
    cond do
      expired?(expires, now) -> {:error, :expired_container_context}
      valid_view?(menu, block, mode, eye, position) -> :ok
      true -> {:error, :invalid_container_context}
    end
  end

  def authorize_action(_, _, _, _, _), do: {:error, :invalid_container_context}

  @doc """
  A grant's decision for `menu`'s block: `:pass` (not a menu use; placement
  goes on), `:open` (a table opens), `:valid` (the entry is the one the grant
  saw), `{menu, block, entry}` (open or refresh with this entry) or an error.
  `above` is the block on a chest.
  """
  def authorize(menu, block, entry, above, position, grant, now)
      when is_map_key(@kinds, menu) and is_map(grant) and is_integer(now) do
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
         true <- kind in @kinds[menu] and mode in @modes,
         true <- is_number(x) and is_number(y) and is_number(z) and is_integer(expires),
         true <-
           hand in [:main, :off] and is_boolean(secondary) and is_boolean(main) and
             is_boolean(off) do
      decide(menu, block, entry, above, position, grant, now)
    else
      _ -> {:error, :invalid_menu_grant}
    end
  end

  def authorize(_, _, _, _, _, _, _), do: {:error, :invalid_menu_grant}

  defp decide(menu, block, entry, above, position, grant, now) do
    opening = grant.kind == :open

    cond do
      expired?(grant.expires, now) ->
        {:error, :expired_menu_grant}

      opening and not opens?(grant) ->
        :pass

      menu == :table and opening ->
        if block == @table and Interaction.within_block?(grant.mode, grant.eye, position),
          do: :open,
          else: :pass

      menu != :table and not entry?(menu, block, entry) ->
        {:error, :missing_menu_entry}

      opening and not Interaction.within_block?(grant.mode, grant.eye, position) ->
        {:error, :invalid_menu_context}

      menu == :chest and opening and not provider?(block, true, above, false) ->
        {:error, :blocked_chest}

      not valid_view?(menu, block, grant.mode, grant.eye, position) ->
        {:error, :invalid_menu_context}

      menu == :table ->
        :valid

      not opening and grant[:menu] != menu ->
        {:error, :invalid_menu_context}

      grant.kind in [:check, :click] and grant[:revision] == entry.revision ->
        :valid

      true ->
        {menu, block, entry}
    end
  end

  @doc """
  A use of a block whose interaction ValiMC cannot perform (a preserved block
  entity): an opening use is refused; one vanilla would not send to the block
  (secondary use with an item) passes on to placement.
  """
  def refuse_use(_block, position, %{kind: :open, mode: mode, expires: expires} = grant, now)
      when mode in @modes and is_integer(expires) do
    cond do
      expired?(expires, now) ->
        {:error, :expired_menu_grant}

      Interaction.within_block?(mode, grant.eye, position) and opens?(grant) ->
        {:error, :unsupported_block_entity}

      true ->
        :pass
    end
  end

  def refuse_use(block, position, grant, now),
    do: authorize(:table, block, nil, nil, position, grant, now)

  @doc "Whether a block on a chest blocks it from opening (a sitting cat does too)."
  def obstructed?(above, false) when is_integer(above) and above >= 0 and above < @count,
    do: (:binary.at(@mask, above >>> 3) &&& 1 <<< (above &&& 7)) != 0

  def obstructed?(_, _), do: true

  @doc "Whether a present chest half with `above` on it opens."
  def provider?(block, true, above, sitting_cat) when is_boolean(sitting_cat),
    do: Chest.ordinary?(block) and not obstructed?(above, sitting_cat)

  def provider?(_, _, _, _), do: false

  defp opens?(grant),
    do:
      Interaction.opens_block_menu?(
        grant.mode,
        grant.hand,
        grant.secondary,
        grant.main,
        grant.off
      )

  # A grant is fresh within the window the connection gives it, never beyond.
  defp expired?(expires, now),
    do: expires <= now or expires > now + Valimc.Txn.Permits.window(250)

  defp entry?(:chest, _block, entry),
    do:
      match?(
        %{rows: rows, slots: slots} when rows in [3, 6] and tuple_size(slots) == rows * 9,
        entry
      )

  defp entry?(menu, block, %{kind: kind, slots: _}) when menu in [:hopper, :dispenser],
    do: Machine.kind(block) == kind

  defp entry?(menu, _block, _entry) when menu in [:hopper, :dispenser], do: false

  defp entry?(:cooking, block, entry) do
    kind = CookingBlocks.kind(block)
    kind != nil and match?(%{kind: ^kind, cooking: %Cooking{}}, entry)
  end
end
