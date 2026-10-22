defmodule Valimc.World.EntityIds do
  @moduledoc """
  Network entity ids (VMC-077h): one `:atomics` counter for players and every
  entity kind, like vanilla's `Entity.ENTITY_COUNTER`. An entity keeps its id
  for the life of the VM, across handoffs between owners, so observers see a
  border crossing as a move. Ids are not persisted: an entity loaded from disk
  gets a fresh one.
  """

  @key {__MODULE__, :counter}
  @max 2_147_483_647

  @doc "Create the counter (application start)."
  def init!, do: :persistent_term.put(@key, :atomics.new(1, signed: false))

  @doc "The next id, or `{:error, :entity_id_exhausted}` past the protocol's range."
  def next do
    case :atomics.add_get(counter(), 1, 1) do
      id when id <= @max -> {:ok, id}
      _ -> {:error, :entity_id_exhausted}
    end
  end

  def valid?(id), do: is_integer(id) and id in 1..@max

  # The application creates the counter before any owner starts; code running
  # without it (vanilla check scripts) creates it on first use.
  defp counter do
    case :persistent_term.get(@key, nil) do
      nil ->
        init!()
        :persistent_term.get(@key)

      counter ->
        counter
    end
  end
end
