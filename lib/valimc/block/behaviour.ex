defmodule Valimc.Block.Behaviour do
  @moduledoc """
  Callbacks for the block behaviour of a state; `Valimc.Block` picks the module by
  the state's generated vanilla block class. `use Valimc.Block.Behaviour` supplies
  the plain-block defaults, so a module overrides only what its class changes.
  """
  @type state :: non_neg_integer()

  @doc "The block-entity kind ValiMC owns for this state, or nil."
  @callback block_entity(state) :: atom() | nil

  @doc """
  The state an `item` of this behaviour places over `previous` (the replaced state),
  clicked on `face` (0..5) in the `upper` half; `request` carries the player's yaw.
  """
  @callback placement(
              item :: non_neg_integer(),
              previous :: state,
              face :: 0..5,
              upper :: boolean(),
              request :: map()
            ) :: {:ok, state} | {:error, atom()}

  @doc "Whether placing `item` may replace this state (placement facts mark these states)."
  @callback replaceable?(
              state,
              item :: non_neg_integer(),
              face :: 0..5,
              upper :: boolean(),
              clicked :: boolean()
            ) :: boolean()

  @doc "Harvested drops that replace the loot table, or `:default`."
  @callback harvest_drops(state) :: {:ok, [Valimc.Protocol.ItemStack.t()]} | :default

  @doc "The state left behind when this state's block is removed."
  @callback after_removal(state) :: state

  defmacro __using__(_) do
    quote do
      @behaviour Valimc.Block.Behaviour

      @impl true
      def block_entity(_state), do: nil

      @impl true
      def placement(item, _previous, _face, _upper, _request),
        do: {:ok, Valimc.Physics.Placement.plain_state(item)}

      @impl true
      def replaceable?(_state, _item, _face, _upper, _clicked), do: false

      @impl true
      def harvest_drops(_state), do: :default

      @impl true
      def after_removal(state), do: Valimc.Physics.FluidBlocks.after_removal(state)

      defoverridable block_entity: 1,
                     placement: 5,
                     replaceable?: 5,
                     harvest_drops: 1,
                     after_removal: 1
    end
  end
end
