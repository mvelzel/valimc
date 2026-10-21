defmodule Valimc.World.BlockSnapshot do
  @moduledoc """
  A region owner's published chunk snapshots: `{{:chunk, cx, cz}, revision,
  sections}` rows in its protected table, written for each chunk once its
  changes are durable. Untouched chunks of a flat world have no row and read
  the base profile; a chunk not generated yet (VMC-075) has an `:absent` row.
  Readers go through `Valimc.World.View`; observations never grant authority.
  """
  alias Valimc.World.Blocks

  @doc "Publish the given chunks of `blocks` at `revision`."
  def publish_chunks(table, %Blocks{} = blocks, chunks, revision) do
    rows =
      for chunk <- chunks do
        case Blocks.snapshot(blocks, chunk) do
          nil -> {{:chunk, chunk}, revision, nil}
          sections -> {{:chunk, chunk}, revision, List.to_tuple(sections)}
        end
      end

    :ets.insert(table, rows)
    :ok
  end

  @doc "Mark `chunks` as not generated yet: reads of them fail until they are published."
  def publish_absent(table, chunks) do
    :ets.insert(table, for(chunk <- chunks, do: {{:chunk, chunk}, 0, :absent}))
    :ok
  end

  @doc "Whether `chunk` is not generated yet (or its owner's table is gone)."
  def absent?(table, chunk) do
    match?([{_, _, :absent}], :ets.lookup(table, {:chunk, chunk}))
  rescue
    ArgumentError -> true
  end
end
