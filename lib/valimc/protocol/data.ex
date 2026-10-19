defmodule Valimc.Protocol.Data do
  @moduledoc "Pinned official 26.3 protocol facts; immutable across connections."
  @path Path.expand("../../../priv/protocol", __DIR__)
  for file <- ~w(packets registries blocks tags) do
    @external_resource Path.join(@path, file <> ".json")
  end

  @packets :json.decode(File.read!(Path.join(@path, "packets.json")))
  @registries :json.decode(File.read!(Path.join(@path, "registries.json")))
  @blocks :json.decode(File.read!(Path.join(@path, "blocks.json")))
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

  def block(name), do: Map.fetch!(@blocks["states"], name)
  def item(name), do: Valimc.Protocol.ItemTypes.id(name)
  def item_block(id), do: @blocks["item_blocks"][Integer.to_string(id)]
  def player_type, do: @blocks["player_entity_type"]
  def global_block_bits, do: ceil(:math.log2(@blocks["state_count"]))
  def block_state_count, do: @blocks["state_count"]
end
