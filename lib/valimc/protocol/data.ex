defmodule Valimc.Protocol.Data do
  @moduledoc "Pinned official protocol facts; immutable across connections."
  alias Valimc.Registry.Blocks
  @path Path.expand("../../../priv/protocol", __DIR__)
  for file <- ~w(packets registries tags) do
    @external_resource Path.join(@path, file <> ".json")
  end

  @packets :json.decode(File.read!(Path.join(@path, "packets.json")))
  @registries :json.decode(File.read!(Path.join(@path, "registries.json")))
  @tags :json.decode(File.read!(Path.join(@path, "tags.json")))

  # Packet ids and names compile to function clauses (binary/integer pattern
  # dispatch). A runtime lookup through the nested JSON maps cost ~5 µs per packet.
  @packet_entries for {state, directions} <- @packets,
                      {direction, packets} <- directions,
                      {name, %{"protocol_id" => id}} <- packets,
                      do:
                        {String.to_atom(state), String.to_atom(direction),
                         String.replace_prefix(name, "minecraft:", ""), id}

  @doc "Protocol id of a packet by state, direction and name (without `minecraft:`)."
  for {state, direction, name, id} <- @packet_entries do
    def id(unquote(state), unquote(direction), unquote(name)), do: unquote(id)
  end

  def id(_state, _direction, name), do: raise("unknown packet #{name}")

  @doc "Packet name for a protocol id, or nil."
  for {state, direction, name, id} <- @packet_entries do
    def name(unquote(state), unquote(direction), unquote(id)), do: unquote(name)
  end

  def name(_state, _direction, _id), do: nil

  @doc "All packet names of a state and direction."
  def names(state, direction),
    do: for({^state, ^direction, name, _} <- @packet_entries, do: name)

  def load! do
    alias Valimc.Protocol.Wire
    tags = Enum.sort(@tags)

    payload = [
      Wire.varint(length(tags)),
      Enum.map(tags, fn {registry, entries} ->
        [
          Wire.string(registry),
          Wire.varint(map_size(entries)),
          Enum.map(Enum.sort(entries), fn {name, ids} ->
            [Wire.string(name), Wire.varint(length(ids)), Enum.map(ids, &Wire.varint/1)]
          end)
        ]
      end)
    ]

    :persistent_term.put({__MODULE__, :tags}, IO.iodata_to_binary(payload))
  end

  def tags_payload, do: :persistent_term.get({__MODULE__, :tags})

  def registries, do: @registries

  @registry_index Map.new(@registries, fn {registry, entries} ->
                    {registry, Map.new(Enum.with_index(entries))}
                  end)

  def registry_id(registry, entry),
    do: @registry_index[registry][entry] || raise("unknown registry entry")

  @doc "The network id of a registry entry, or nil."
  def find_registry_id(registry, entry), do: @registry_index[registry][entry]

  # Items place the default state of the block with the same registry name.
  @item_blocks for id <- 0..(Valimc.Protocol.ItemTypes.count() - 1),
                   "minecraft:" <> name = Valimc.Protocol.ItemTypes.item(id)["name"],
                   Blocks.id(name) != nil,
                   into: %{},
                   do: {id, Blocks.default_state(name)}
  @global_block_bits ceil(:math.log2(Blocks.state_count()))

  def block(name), do: Blocks.default_state(name)
  def item(name), do: Valimc.Protocol.ItemTypes.id(name)
  def item_block(id), do: Map.get(@item_blocks, id)
  def player_type, do: Valimc.Protocol.EntityTypes.id("player")
  def global_block_bits, do: @global_block_bits

  @global_biome_bits (length(@registries["minecraft:worldgen/biome"]) - 1)
                     |> Integer.digits(2)
                     |> length()
  @doc "Bits of a global biome id in chunk packets (ceil log2 of the biome registry size)."
  def global_biome_bits, do: @global_biome_bits
  def block_state_count, do: Blocks.state_count()
end
