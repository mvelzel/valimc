defmodule Valimc.Data.Blocks do
  @moduledoc """
  The generated block registry (`BlockRegistryMetadata`): every block in registry
  order with its contiguous state run, default state, vanilla block class and
  property definitions. A state's offset in its run is the mixed radix of its
  property values, the last property varying fastest, so properties decode without
  a per-state table. Per-state facts are `Valimc.Data.BlockFacts`.
  """
  use Valimc.Data.Facts, "registry/blocks.json"
  @count @facts["state_count"]
  @classes List.to_tuple(@facts["classes"])
  @definitions @facts["properties"]
               |> Enum.map(fn [name, values] -> {name, List.to_tuple(values)} end)
               |> List.to_tuple()
  @rows @facts["blocks"]
        |> Enum.map(fn [name, first, default, class, properties] ->
          properties = Enum.map(properties, &elem(@definitions, &1))
          size = Enum.reduce(properties, 1, fn {_, values}, n -> n * tuple_size(values) end)

          %{
            name: name,
            first: first,
            last: first + size - 1,
            default: default,
            class: elem(@classes, class),
            properties: properties
          }
        end)
  @blocks List.to_tuple(@rows)
  @ids @rows |> Enum.with_index() |> Map.new(fn {row, id} -> {row.name, id} end)
  # Two bytes per state: the owning block's registry id.
  @state_blocks @rows
                |> Enum.with_index()
                |> Enum.map(fn {row, id} ->
                  :binary.copy(<<id::16>>, row.last - row.first + 1)
                end)
                |> IO.iodata_to_binary()
  unless @facts["block_count"] == tuple_size(@blocks) and
           map_size(@ids) == tuple_size(@blocks) and byte_size(@state_blocks) == @count * 2 and
           Enum.all?(Enum.zip(@rows, tl(@rows) ++ [%{first: @count}]), fn {row, next} ->
             row.last + 1 == next.first and row.default in row.first..row.last
           end),
         do: raise("Wrong or non-contiguous block registry")

  def state_count, do: @count

  @doc "The registry file as the Rust core reads it (`priv/registry/blocks.json`, at run time)."
  def native_facts, do: Valimc.Data.Facts.read!("registry/blocks.json")

  def block_count, do: tuple_size(@blocks)

  @doc "Registry id of the block that owns `state`."
  def block_id(state) when is_integer(state) and state >= 0 and state < @count do
    <<id::16>> = binary_part(@state_blocks, state * 2, 2)
    id
  end

  @doc "Registry id of a block name (without `minecraft:`), or nil."
  def id(name) when is_binary(name), do: Map.get(@ids, name)

  def name(id) when is_integer(id) and id >= 0 and id < tuple_size(@blocks),
    do: elem(@blocks, id).name

  def default_state(name), do: elem(@blocks, Map.fetch!(@ids, name)).default
  def states(name), do: elem(@blocks, Map.fetch!(@ids, name)) |> then(&(&1.first..&1.last))

  @doc "Vanilla class (relative to `net.minecraft.world.level.block`) of the block owning `state`."
  def class(state), do: elem(@blocks, block_id(state)).class

  @doc "Every block class with the registry ids of its blocks."
  def classes do
    @rows
    |> Enum.with_index()
    |> Enum.group_by(fn {row, _} -> row.class end, fn {_, id} -> id end)
  end

  @doc "Property name/value pairs of `state`, in definition order."
  def properties(state) do
    block = elem(@blocks, block_id(state))

    {pairs, 0} =
      List.foldr(block.properties, {[], state - block.first}, fn {name, values}, {acc, rest} ->
        size = tuple_size(values)
        {[{name, elem(values, rem(rest, size))} | acc], div(rest, size)}
      end)

    pairs
  end

  @doc "Property names and value tuples of block `name`, in state order."
  def definitions(name), do: elem(@blocks, Map.fetch!(@ids, name)).properties

  @doc "The state of block `name` with `changes` applied to its default properties."
  def state(name, changes \\ %{}) when is_map(changes) do
    block = elem(@blocks, Map.fetch!(@ids, name))
    current = Map.new(properties(block.default))

    Enum.reduce(block.properties, 0, fn {property, values}, offset ->
      value = Map.get(changes, property, current[property])
      index = Enum.find_index(Tuple.to_list(values), &(&1 == value)) || raise ArgumentError
      offset * tuple_size(values) + index
    end) + block.first
  end
end
