defmodule Valimc.Player.Use do
  @moduledoc "Transient player-owned use timer; only admitted owner ticks can advance it."
  alias Valimc.Protocol.ItemStack
  import Bitwise
  defstruct [:hand, :item_id, :remaining, blocking: false, kind: nil, sounds: 0]

  # A shield's use duration (`ShieldItem`/`blocks_attacks` items: 72000 ticks).
  @blocking_ticks 72_000

  @doc "A raised shield (an item with `blocks_attacks`, VMC-037n)."
  def blocking(%ItemStack{item_id: id}, hand) when hand in [:main, :off],
    do: %__MODULE__{hand: hand, item_id: id, remaining: @blocking_ticks, blocking: true}

  @doc "A drawn bow or charging crossbow (`kind` `:bow` or `:crossbow`, VMC-037o): 72000 ticks."
  def drawing(%ItemStack{item_id: id}, hand, kind)
      when hand in [:main, :off] and kind in [:bow, :crossbow],
      do: %__MODULE__{hand: hand, item_id: id, remaining: @blocking_ticks, kind: kind}

  @doc "Ticks a blocking or drawing use has lasted (`getUseDuration - useItemRemaining`)."
  def elapsed(%__MODULE__{remaining: remaining} = use) when use.blocking or use.kind != nil,
    do: @blocking_ticks - remaining

  def new(%ItemStack{item_id: id}, hand, %{consumable: %{"ticks" => ticks}})
      when hand in [:main, :off] and is_integer(ticks) and ticks in 0..2_147_483_647,
      do: %__MODULE__{hand: hand, item_id: id, remaining: ticks}

  # Native tick refreshes the use stack by item type, including current components/count.
  def tick(%__MODULE__{item_id: id} = use, %ItemStack{item_id: id}) do
    if use.remaining <= 1,
      do: {:finish, %{use | remaining: 0}},
      else: {:using, %{use | remaining: use.remaining - 1}}
  end

  def tick(%__MODULE__{}, _), do: {:cancel, nil}
  def start_flags(flags, :main), do: (flags &&& bnot(3)) ||| 1
  def start_flags(flags, :off), do: flags ||| 3
  def stop_flags(flags), do: flags &&& bnot(1)
end
