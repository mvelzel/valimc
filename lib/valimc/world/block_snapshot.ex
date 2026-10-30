defmodule Valimc.World.BlockSnapshot do
  @moduledoc """
  A region owner's published chunk snapshots: `{{:chunk, cx, cz}, snapshot}`
  rows in its protected table, written for each chunk in the step that adopts
  its change and before any client is told of it (VMC-077f). A snapshot is a
  Rust handle that shares the chunk's sections with the owner's store
  (VMC-077p): republishing a chunk copies pointers, the store clones only the
  sections it writes afterwards, and each section keeps the revision of the
  publication that last changed it. Rows move with the table on a section
  handoff (VMC-077j). A chunk not generated yet (VMC-075) has an `:absent`
  row. A `:generated` counter row counts the publications that turned chunks
  from absent (or unpublished) to generated. Readers go through
  `Valimc.World.View`; observations never grant authority.
  """
  alias Valimc.World.Blocks

  @doc "Publish the given chunks of `blocks` at `revision`."
  def publish_chunks(table, %Blocks{} = blocks, chunks, revision) do
    previous = for chunk <- chunks, do: {chunk, published(table, chunk)}
    handles = Blocks.snapshots(blocks, previous, revision)
    :ets.insert(table, Enum.zip_with(chunks, handles, &{{:chunk, &1}, &2}))

    # After the rows, so a reader that sees the new count sees them too.
    if Enum.any?(previous, &match?({_, nil}, &1)),
      do: :ets.update_counter(table, :generated, 1, {:generated, 0})

    :ok
  end

  @doc """
  How many publications made chunks of the table generated (VMC-081k): a
  reader that saw some chunks absent need not look at them again while this
  count is unchanged. Nil once the table is gone.
  """
  def generated(table) do
    case :ets.lookup(table, :generated) do
      [{_, count}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Mark `chunks` as not generated yet: reads of them fail until they are published."
  def publish_absent(table, chunks) do
    :ets.insert(table, for(chunk <- chunks, do: {{:chunk, chunk}, :absent}))
    :ok
  end

  @doc "Whether `chunk` is not generated yet (or its owner's table is gone)."
  def absent?(table, chunk) do
    match?([{_, :absent}], :ets.lookup(table, {:chunk, chunk}))
  rescue
    ArgumentError -> true
  end

  @doc """
  `{revision, section_revisions}` of `chunk`'s publication: its revision and,
  per section bottom first, the revision of the publication that last
  changed it; nil when none is readable.
  """
  def revisions(table, chunk) do
    case published(table, chunk) do
      nil -> nil
      handle -> Valimc.Native.snapshot_revisions(handle)
    end
  end

  defp published(table, chunk) do
    case :ets.lookup(table, {:chunk, chunk}) do
      [{_, handle}] when is_reference(handle) -> handle
      _ -> nil
    end
  end
end
