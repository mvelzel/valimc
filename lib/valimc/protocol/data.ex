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

  def id(state, direction, name),
    do:
      @packets[Atom.to_string(state)][Atom.to_string(direction)]["minecraft:" <> name][
        "protocol_id"
      ] || raise("unknown packet #{name}")

  def name(state, direction, id) do
    :persistent_term.get({__MODULE__, state, direction})[id]
  end

  def load! do
    for {state, state_name} <- [
          handshake: "handshake",
          status: "status",
          login: "login",
          configuration: "configuration",
          play: "play"
        ],
        direction <- [:clientbound, :serverbound] do
      names =
        Map.new(@packets[state_name][Atom.to_string(direction)] || %{}, fn {name, value} ->
          {value["protocol_id"], String.replace_prefix(name, "minecraft:", "")}
        end)

      :persistent_term.put({__MODULE__, state, direction}, names)
    end

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

  def registry_id(registry, entry),
    do: Enum.find_index(@registries[registry], &(&1 == entry)) || raise("unknown registry entry")

  def block(name), do: Map.fetch!(@blocks["states"], name)
  def item(name), do: Valimc.Protocol.ItemTypes.id(name)
  def item_block(id), do: @blocks["item_blocks"][Integer.to_string(id)]
  def player_type, do: @blocks["player_entity_type"]
  def global_block_bits, do: ceil(:math.log2(@blocks["state_count"]))
  def block_state_count, do: @blocks["state_count"]
end
