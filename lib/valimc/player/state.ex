defmodule Valimc.Player.State do
  @moduledoc """
  A player's durable state (VMC-077i1): every field its file keeps, one typed
  struct with one codec.

  The file is a checkpoint of keyed records (`Valimc.Storage.Checkpoint`): one
  record per field, `{:player, field}`, and one per occupied inventory slot,
  `{:slot, n}`, so a player's changes diff into records as a section's do. No
  other format is read (D4). A save keeps every durable field
  (`merge/2` keeps the transfer-bound ones of the older state).

  `game_mode` nil means the server's default. `transfer_sequence` and `outbox`
  belong to the player-sourced transfers until those become owner calls
  (VMC-077i3).
  """
  alias Valimc.{GameMode, Inventory, PlayerFood, PlayerProgression, PlayerStore}

  alias Valimc.{
    PlayerContainerIntent,
    PlayerMiningIntent,
    PlayerPickupIntent,
    PlayerPlacementIntent
  }

  alias Valimc.Living
  alias Valimc.Living.{Air, Burning, Effects, Freezing, Health}
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.Storage.Checkpoint
  alias Valimc.World.ItemTransfers

  defstruct pose: %{x: 0.0, y: 64.0, z: 0.0, yaw: 0.0, pitch: 0.0},
            dimension: :overworld,
            inventory: %Inventory{},
            game_mode: nil,
            flying: false,
            health: %{value: 20.0, hurt_ticks: 0, death_ticks: 0},
            absorption: 0.0,
            effects: %{},
            fire_ticks: 0,
            air_supply: 300,
            frozen_ticks: 0,
            food: %PlayerFood{},
            progression: %PlayerProgression{},
            fall_distance: 0.0,
            velocity: {0.0, 0.0, 0.0},
            last_death: nil,
            death_dimension: :overworld,
            portal_cooldown: 0,
            seen_credits: false,
            transfer_sequence: 0,
            outbox: nil

  @type t :: %__MODULE__{}

  @dimensions [:overworld, :the_nether, :the_end]
  @max_sequence 18_446_744_073_709_551_615
  @inventory_bytes 524_288
  @outbox_bytes 1_048_576
  @max_bytes 4_194_304
  # What a save of a live player may not overwrite while a transfer is pending.
  @transfer_bound [:inventory, :transfer_sequence, :outbox]

  def max_bytes, do: @max_bytes

  @doc "The durable state of the live `player` map and its inventory."
  def capture(player, %Inventory{} = inventory) do
    living = Living.saved(Map.get(player, :living, %Living{}))
    motion = Map.get(player, :motion)

    flying =
      case player do
        %{abilities: %{flying: flying}} -> flying
        _ -> false
      end

    struct(
      __MODULE__,
      Map.merge(living, %{
        pose: PlayerStore.pose(player),
        inventory: inventory,
        game_mode: Map.get(player, :game_mode),
        flying: flying,
        food: Map.get(player, :food, %PlayerFood{}),
        progression: Map.get(player, :progression, %PlayerProgression{}),
        fall_distance: if(motion, do: motion.fall_distance, else: 0.0),
        velocity: if(motion, do: motion.velocity, else: {0.0, 0.0, 0.0}),
        last_death: Map.get(player, :last_death),
        dimension: Map.get(player, :dimension, :overworld),
        death_dimension: Map.get(player, :death_dimension, :overworld),
        portal_cooldown: Map.get(player, :portal_cooldown, 0),
        seen_credits: Map.get(player, :seen_credits, false)
      })
    )
  end

  @doc "A save of `live` over `base`: every durable field, but the transfer-bound ones of `base`."
  def merge(base, live),
    do: struct(new(live), Map.take(new(base), @transfer_bound))

  @doc "The state without a pending transfer (what a transfer's plan checks it against)."
  def strip(state), do: %{new(state) | transfer_sequence: 0, outbox: nil}

  @doc "A state from a map of its fields (a fixture's partial map takes the defaults)."
  def new(%__MODULE__{} = state), do: state
  def new(%{pose: _} = fields), do: struct(__MODULE__, fields)

  @doc "The keyed records the file holds."
  def records(%__MODULE__{inventory: inventory} = state) do
    fields =
      state
      |> Map.from_struct()
      |> Map.delete(:inventory)
      |> Map.merge(%{
        selected: inventory.selected,
        carried: inventory.carried,
        table_inputs: inventory.table_inputs
      })

    for({field, value} <- fields, into: %{}, do: {{:player, field}, value})
    |> Map.merge(for {slot, stack} <- inventory.slots, into: %{}, do: {{:slot, slot}, stack})
  end

  @doc "The state of `records`, validated."
  def from_records(records, uuid) when is_map(records) do
    {fields, slots} =
      Enum.reduce(records, {%{}, %{}}, fn
        {{:player, field}, value}, {fields, slots} -> {Map.put(fields, field, value), slots}
        {{:slot, slot}, stack}, {fields, slots} -> {fields, Map.put(slots, slot, stack)}
        _, _ -> throw(:invalid_player_file)
      end)

    {inventory_fields, fields} = Map.split(fields, [:selected, :carried, :table_inputs])
    {id, fields} = Map.pop(fields, :uuid)
    keys = Map.keys(Map.from_struct(%__MODULE__{})) -- [:inventory]

    with true <- id == uuid and Enum.sort(Map.keys(fields)) == Enum.sort(keys),
         true <- map_size(inventory_fields) == 3 do
      inventory = struct(%Inventory{slots: slots}, inventory_fields)
      state = struct(%__MODULE__{inventory: inventory}, fields)
      with :ok <- validate(uuid, state), do: {:ok, state}
    else
      _ -> {:error, :invalid_player_file}
    end
  catch
    :invalid_player_file -> {:error, :invalid_player_file}
  end

  @doc "The file's bytes, after validating every field."
  def encode(<<_::128>> = uuid, %{pose: _} = state) do
    state = new(state)

    with :ok <- validate(uuid, state) do
      records = Map.put(records(state), {:player, :uuid}, uuid)
      {:ok, IO.iodata_to_binary(Checkpoint.encode(0, records))}
    end
  end

  def encode(_, _), do: {:error, :invalid_player_state}

  def decode(bytes, <<_::128>> = uuid) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    case Checkpoint.decode(bytes) do
      {:ok, %{records: records}} -> from_records(records, uuid)
      _ -> {:error, :invalid_player_file}
    end
  end

  def decode(_, _), do: {:error, :invalid_player_file}

  @doc "Whether every field holds what the file may hold: `:ok` or the first refusal."
  def validate(uuid, %{pose: _} = state) do
    state = new(state)

    checks = [
      invalid_pose: PlayerStore.valid_pose?(state.pose),
      invalid_dimension: state.dimension in @dimensions and state.death_dimension in @dimensions,
      invalid_inventory: inventory?(state.inventory),
      invalid_game_mode:
        state.game_mode == nil or match?({:ok, _}, GameMode.encode(state.game_mode)),
      invalid_flight_state: is_boolean(state.flying),
      invalid_health: Health.valid_saved?(state.health),
      invalid_absorption: Health.valid_absorption?(state.absorption),
      invalid_player_effects: Effects.valid?(state.effects),
      invalid_fire_ticks: Burning.valid?(state.fire_ticks),
      invalid_air_supply: Air.valid?(state.air_supply),
      invalid_frozen_ticks: Freezing.valid_ticks?(state.frozen_ticks),
      invalid_food: PlayerFood.valid?(state.food),
      invalid_player_progression: PlayerProgression.valid?(state.progression),
      invalid_fall_distance: Valimc.PlayerMotion.valid_distance?(state.fall_distance),
      invalid_velocity: Valimc.PlayerKinetics.valid_velocity?(state.velocity),
      invalid_last_death: Valimc.PlayerLife.valid_location?(state.last_death),
      invalid_portal_cooldown:
        is_integer(state.portal_cooldown) and state.portal_cooldown in 0..2_147_483_647,
      invalid_seen_credits: is_boolean(state.seen_credits),
      invalid_transfer_sequence:
        is_integer(state.transfer_sequence) and state.transfer_sequence in 0..@max_sequence and
          (state.transfer_sequence > 0 or state.outbox == nil)
    ]

    checks = checks ++ [{outbox_refusal(state.outbox), outbox?(uuid, state)}]

    case Enum.find(checks, fn {_, valid} -> valid != true end) do
      nil -> :ok
      {reason, _} -> {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_player_state}
  end

  # Slots 1..45, the cursor and the open table's grid hold real stacks, within
  # the bytes a player's inventory may take.
  defp inventory?(%Inventory{slots: slots, selected: selected, table_inputs: table} = inventory)
       when is_map(slots) do
    table_ok = table == nil or (is_tuple(table) and tuple_size(table) == 9)

    stacks =
      Map.values(slots) ++
        [inventory.carried] ++ if(table_ok and table, do: Tuple.to_list(table), else: [])

    is_integer(selected) and selected in 0..8 and table_ok and
      Enum.all?(Map.keys(slots), &(is_integer(&1) and &1 in 1..45)) and
      Enum.all?(Map.values(slots), &(&1 != nil)) and
      Enum.reduce_while(stacks, 0, fn stack, size ->
        case stack_bytes(stack) do
          {:ok, bytes} when size + bytes <= @inventory_bytes -> {:cont, size + bytes}
          _ -> {:halt, false}
        end
      end) != false
  end

  defp inventory?(_), do: false

  defp stack_bytes(nil), do: {:ok, 0}

  defp stack_bytes(%ItemStack{components: components, removed: %MapSet{}} = stack)
       when is_map(components) do
    if stack.item_id == ItemTypes.id("air"),
      do: :error,
      else: {:ok, IO.iodata_length(ItemStack.encode(stack))}
  catch
    _, _ -> :error
  end

  defp stack_bytes(_), do: :error

  defp outbox_refusal(%{kind: :mining}), do: :invalid_mining_snapshot
  defp outbox_refusal(%{kind: :placement}), do: :invalid_placement_snapshot
  defp outbox_refusal(%{kind: :pickup}), do: :invalid_pickup_snapshot
  defp outbox_refusal(%{kind: :container}), do: :invalid_container_snapshot
  defp outbox_refusal(_), do: :invalid_outbox

  # A pending transfer's intent, as its kind encodes and checks it.
  defp outbox?(_uuid, %{outbox: nil}), do: true

  defp outbox?(uuid, %{transfer_sequence: sequence, outbox: outbox, inventory: inventory} = state) do
    case outbox do
      %{kind: :mining} ->
        match?({:ok, _}, PlayerMiningIntent.encode(uuid, sequence, outbox)) and
          PlayerMiningIntent.matches_inventory?(outbox, inventory)

      %{kind: :placement} ->
        match?({:ok, _}, PlayerPlacementIntent.encode(uuid, sequence, outbox)) and
          PlayerPlacementIntent.matches_inventory?(outbox, inventory)

      %{kind: :pickup} ->
        match?({:ok, _}, PlayerPickupIntent.encode(uuid, sequence, outbox)) and
          PlayerPickupIntent.matches_snapshot?(outbox, state)

      %{kind: :container} ->
        match?({:ok, _}, PlayerContainerIntent.encode(uuid, sequence, outbox)) and
          PlayerContainerIntent.matches_snapshot?(outbox, state)

      %{key: key, records: records} ->
        case ItemTransfers.encode_request(key, %{
               source: uuid,
               sequence: sequence,
               records: records
             }) do
          {:ok, bytes, _digest} -> byte_size(bytes) <= @outbox_bytes
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc "The pending item transfer's request: `{:ok, key, request, digest}`."
  def transfer_request(_uuid, %{outbox: %{kind: _}}), do: {:error, :wrong_transfer_kind}

  def transfer_request(<<_::128>> = uuid, %{
        transfer_sequence: sequence,
        outbox: %{key: key, records: records}
      }) do
    request = %{source: uuid, sequence: sequence, records: records}
    with {:ok, digest} <- ItemTransfers.digest(key, request), do: {:ok, key, request, digest}
  end

  def transfer_request(_, _), do: {:error, :no_pending_transfer}
end
