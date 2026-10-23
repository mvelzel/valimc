defmodule Valimc.Blocks.Chest do
  @moduledoc "Ordinary chest (`ChestBlock`): each block owns its 27 slots; a joined menu reads both."
  use Valimc.Blocks.Behaviour
  use Valimc.Data.Facts, "protocol/chest_states.json"

  @single MapSet.new(@facts["single_states"])
  @ordinary MapSet.new(@facts["states"], & &1["state"])
  @double for state <- @facts["states"],
              state["part"] != "single",
              into: MapSet.new(),
              do: state["state"]
  @states Map.new(@facts["states"], &{&1["state"], &1})
  @steps %{"north" => {0, -1}, "east" => {1, 0}, "south" => {0, 1}, "west" => {-1, 0}}
  @clockwise %{"north" => "east", "east" => "south", "south" => "west", "west" => "north"}
  @counter Map.new(@clockwise, fn {a, b} -> {b, a} end)

  @doc "Whether a block state is an ordinary chest, single or half of a double."
  def ordinary?(block), do: MapSet.member?(@ordinary, block)

  @doc "Whether a block state is a single ordinary chest (the ones that own a container)."
  def single?(block), do: MapSet.member?(@single, block)
  def single_states, do: @single

  @doc "The ordinary chest states that are half of a double chest."
  def double_states, do: @double

  @doc "The connected cell of a half, or nil for a single chest."
  def connected_position(state, {x, y, z}) do
    case @states[state] do
      %{"part" => part, "facing" => facing} when part != "single" ->
        direction = if part == "left", do: @clockwise[facing], else: @counter[facing]
        {dx, dz} = @steps[direction]
        {x + dx, y, z + dz}

      _ ->
        nil
    end
  end

  @doc "The sound's block coordinate: a joined chest sounds once at its center."
  def sound_position(state, {x, y, z} = position) do
    case @states[state] do
      %{"part" => "left"} ->
        nil

      %{"part" => "right"} ->
        {ox, _, oz} = connected_position(state, position)
        {(x + ox) / 2, y, (z + oz) / 2}

      _ ->
        position
    end
  end

  @doc "The positions of a chest's container, in vanilla's slot order (right half first)."
  def positions(state, position, read) do
    case @states[state] do
      %{"part" => part, "facing" => facing} when part != "single" ->
        other = connected_position(state, position)

        case @states[read.(other)] do
          %{"part" => partner, "facing" => ^facing}
          when partner != "single" and partner != part ->
            if part == "right", do: [position, other], else: [other, position]

          _ ->
            [position]
        end

      _ ->
        [position]
    end
  end

  @impl true
  def block_entity(state), do: if(ordinary?(state), do: :chest)
end
