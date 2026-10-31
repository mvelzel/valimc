defmodule Valimc.Menus.Offers do
  @moduledoc """
  A merchant's offers (VMC-044b1): vanilla's `MerchantOffer` as a map

      %{buy: stack, buy_b: stack | nil, sell: stack, uses: 0, max_uses: n,
        reward_exp: true, special_price: 0, demand: 0, price_multiplier: f,
        xp: n}

  where `buy` and `buy_b` are the `ItemCost`s as stacks (item, count and the
  components they ask for) and `sell` the result.

  `draw/6` is `AbstractVillager.addOffersFromTradeSet` over the trade facts
  (`priv/loot/trades.json`, `valimc_core::loot::trades`): the caller owns
  the set's random sequence and passes its state in and takes the advanced
  state back. `sets/2` names the sets a merchant draws: a profession's at a
  level, or the wandering trader's.
  """
  alias Valimc.Blocks.Loot
  alias Valimc.Native
  alias Valimc.Protocol.ItemData

  @doc """
  The trade sets `profession` draws at `level` (`nil` for a wandering
  trader's), each with its random sequence: `[{set, sequence}]`.
  """
  def sets(profession, level), do: Native.loot_trade_sets(Loot.registry(), profession, level)

  @doc "A random sequence's first state for world seed `seed` (`RandomSequences`, salt 0)."
  def sequence(seed, id), do: Native.loot_sequence(seed, 0, id)

  @doc """
  Draw `set`'s offers for a merchant of `villager_type` at `origin` from the
  sequence state `state`: `{:ok, offers, state, next_map}`, or `{:locate,
  tag, radius}` when an exploration map needs a structure `structures` (a
  list of `{tag, {x, y, z} | nil}`, `"*"` for any) does not answer; nothing
  is drawn then. Options: `:registry`.
  """
  def draw(set, {_, _} = state, villager_type, {x, y, z}, structures, next_map, opts \\ []) do
    registry = Keyword.get_lazy(opts, :registry, &Loot.registry/0)

    case Native.loot_trades(
           registry,
           set,
           state,
           villager_type,
           {x * 1.0, y * 1.0, z * 1.0},
           structures,
           next_map
         ) do
      {:ok, {:offers, rows, state, next_map}} ->
        {:ok, Enum.map(rows, &offer/1), state, next_map}

      {:ok, {:locate, tag, radius}} ->
        {:locate, tag, radius}

      {:error, _} = error ->
        error
    end
  end

  @doc "`MerchantOffer.updateDemand` of every offer (VMC-044b3)."
  def update_demand(offers),
    do:
      Enum.map(offers, fn o ->
        %{o | demand: o.demand + o.uses - (o.max_uses - o.uses)}
      end)

  defp offer({buy, buy_b, sell, max_uses, xp, multiplier}) do
    %{
      buy: stack!(buy),
      buy_b: if(buy_b, do: stack!(buy_b)),
      sell: stack!(sell),
      uses: 0,
      max_uses: max_uses,
      reward_exp: true,
      special_price: 0,
      demand: 0,
      price_multiplier: Valimc.Data.Float32.round(multiplier),
      xp: xp
    }
  end

  defp stack!(tag) do
    {:ok, stack} = ItemData.stack(tag)
    stack
  end
end
