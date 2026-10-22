defmodule Valimc.Player.Use do
  @moduledoc "Transient player-owned use timer; only admitted owner ticks can advance it."
  alias Valimc.Protocol.ItemStack
  import Bitwise
  defstruct [:hand, :item_id, :remaining]

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
