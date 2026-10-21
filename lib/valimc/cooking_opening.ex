defmodule Valimc.CookingOpening do
  @moduledoc "Fresh furnace-family view/action admission over region-owned metadata."
  alias Valimc.{Cooking, PlayerInteraction}
  alias Valimc.Physics.CookingBlocks
  @modes [:survival, :creative, :adventure, :spectator]

  def valid_view?(block, mode, {x, y, z} = eye, position)
      when mode in @modes and is_number(x) and is_number(y) and is_number(z),
      do:
        CookingBlocks.kind(block) != nil and
          PlayerInteraction.within_block?(mode, eye, position, 4.0)

  def valid_view?(_, _, _, _), do: false

  def authorize_action(
        block,
        position,
        %{mode: mode, eye: eye, health: hp, expires: expires},
        now
      )
      when mode in [:survival, :creative, :adventure] and is_number(hp) and hp > 0 and
             is_integer(expires) and is_integer(now) do
    cond do
      expires <= now or expires > now + Valimc.Txn.Permits.window(250) ->
        {:error, :expired_container_context}

      valid_view?(block, mode, eye, position) ->
        :ok

      true ->
        {:error, :invalid_container_context}
    end
  end

  def authorize_action(_, _, _, _), do: {:error, :invalid_container_context}

  def authorize(block, entry, position, grant, now) when is_map(grant) and is_integer(now) do
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
         true <- kind in [:open, :subscribe, :check, :click, :refresh] and mode in @modes,
         true <- is_number(x) and is_number(y) and is_number(z) and is_integer(expires),
         true <-
           hand in [:main, :off] and is_boolean(secondary) and is_boolean(main) and
             is_boolean(off) do
      block_kind = CookingBlocks.kind(block)

      cond do
        expires <= now or expires > now + Valimc.Txn.Permits.window(250) ->
          {:error, :expired_cooking_grant}

        kind == :open and
            not PlayerInteraction.opens_block_menu?(mode, hand, secondary, main, off) ->
          :pass

        not match?(%{kind: ^block_kind, cooking: %Cooking{}}, entry) or block_kind == nil ->
          {:error, :missing_cooking_entry}

        kind == :open and not PlayerInteraction.within_block?(mode, grant.eye, position) ->
          {:error, :invalid_cooking_context}

        not valid_view?(block, mode, grant.eye, position) ->
          {:error, :invalid_cooking_context}

        kind != :open and grant[:menu] != :cooking ->
          {:error, :invalid_cooking_context}

        kind in [:check, :click] and grant[:revision] == entry.revision ->
          :valid

        true ->
          {:cooking, block, entry}
      end
    else
      _ -> {:error, :invalid_cooking_grant}
    end
  end

  def authorize(_, _, _, _, _), do: {:error, :invalid_cooking_grant}
end
