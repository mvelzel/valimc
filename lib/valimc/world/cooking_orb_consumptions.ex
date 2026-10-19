defmodule Valimc.World.CookingOrbConsumptions do
  @moduledoc "Append-only consumed-unit counters; creation/adoption records are never rewritten or resurrected."
  alias Valimc.World.CookingOrbs
  def new, do: %{revision: 0, counts: %{}}
  def max_bytes, do: 10 + CookingOrbs.max_records() * 20

  def births(containers) do
    imported =
      Map.new(containers.orb_transfers.incoming, fn {id, request} ->
        {id, CookingOrbs.records(id, request.award)}
      end)

    awards = Map.merge(containers.cooking_orbs, imported)
    rows = for {_, records} <- awards, row <- records, do: row
    records = Map.new(rows)
    true = map_size(records) == length(rows) and length(rows) <= CookingOrbs.max_records()
    records
  end

  def take(containers, uuid, value, consumed) do
    with %{value: ^value, count: count} <- births(containers)[uuid],
         true <- is_integer(consumed) and consumed >= 0 and consumed < count,
         true <- Map.get(containers.orb_consumption.counts, uuid, 0) == consumed do
      ledger = containers.orb_consumption

      next = %{
        ledger
        | revision: ledger.revision + 1,
          counts: Map.put(ledger.counts, uuid, consumed + 1)
      }

      {:ok, %{containers | orb_consumption: next}}
    else
      _ -> {:error, :stale_experience_orb}
    end
  end

  def encode(%{revision: revision, counts: counts} = ledger, containers)
      when map_size(ledger) == 2 and is_map(counts) do
    true = map_size(counts) <= CookingOrbs.max_records()
    true = is_integer(revision) and revision >= 0 and revision == Enum.sum(Map.values(counts))
    births = births(containers)

    rows =
      Enum.map(Enum.sort(counts), fn {<<_::128>> = uuid, consumed} ->
        %{count: count} = Map.fetch!(births, uuid)
        true = is_integer(consumed) and consumed in 1..count
        <<uuid::binary, consumed::32>>
      end)

    {:ok, IO.iodata_to_binary([<<revision::64, map_size(counts)::16>>, rows])}
  rescue
    _ -> {:error, :invalid_orb_consumption}
  end

  def encode(_, _), do: {:error, :invalid_orb_consumption}

  def decode(bytes, containers) when is_binary(bytes) and byte_size(bytes) <= 56_330 do
    <<revision::64, count::16, rows::binary>> = bytes
    true = count <= CookingOrbs.max_records() and byte_size(rows) == count * 20
    entries = for <<uuid::binary-size(16), consumed::32 <- rows>>, do: {uuid, consumed}
    counts = Map.new(entries)
    true = map_size(counts) == count
    ledger = %{revision: revision, counts: counts}
    {:ok, ^bytes} = encode(ledger, containers)
    {:ok, ledger}
  rescue
    _ -> {:error, :invalid_orb_consumption}
  end

  def decode(_, _), do: {:error, :invalid_orb_consumption}
end
