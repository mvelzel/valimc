defmodule Valimc.World.BlockSnapshot do
  @moduledoc """
  A region owner's published chunk snapshots: `{{:chunk, cx, cz}, revision,
  sections, heights, biomes}` rows in its protected table, written for each
  chunk in the step that adopts its change and before any client is told of
  it (VMC-077f), with the heightmaps and biomes Rust computes beside the
  sections (VMC-077e). An untouched chunk of a flat world has nil sections and
  reads the base profile; a chunk not generated yet (VMC-075) has an `:absent`
  row.
  Readers go through `Valimc.World.View`; observations never grant authority.
  """
  alias Valimc.World.Blocks

  @doc "Publish the given chunks of `blocks` at `revision`."
  def publish_chunks(table, %Blocks{} = blocks, chunks, revision) do
    rows =
      for chunk <- chunks do
        sections = Blocks.snapshot(blocks, chunk)
        {heights, biomes} = Blocks.column_facts(blocks, chunk)
        {{:chunk, chunk}, revision, sections && List.to_tuple(sections), heights, biomes}
      end

    :ets.insert(table, rows)
    :ok
  end

  @doc "Mark `chunks` as not generated yet: reads of them fail until they are published."
  def publish_absent(table, chunks) do
    :ets.insert(table, for(chunk <- chunks, do: {{:chunk, chunk}, 0, :absent, nil, nil}))
    :ok
  end

  @doc "Whether `chunk` is not generated yet (or its owner's table is gone)."
  def absent?(table, chunk) do
    match?([{_, _, :absent, _, _}], :ets.lookup(table, {:chunk, chunk}))
  rescue
    ArgumentError -> true
  end
end
