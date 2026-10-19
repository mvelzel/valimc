defmodule Valimc.World.CookingOrbs do
  @moduledoc "Bounded, replayable cooking XP materialization proposals; pickup remains inactive."
  alias Valimc.World.Containers
  @values [2477, 1237, 617, 307, 149, 73, 37, 17, 7, 3, 1]
  @max_awards 256
  @max_bytes 2 + @max_awards * (33 + 11 * 46)
  @max_experience 2_147_483_647
  def max_bytes, do: @max_bytes
  def max_records, do: @max_awards * length(@values)

  @doc "Native denomination histogram in eleven divisions, independent of XP magnitude."
  def split(amount) when is_integer(amount) and amount in 0..@max_experience do
    {groups, 0} =
      Enum.reduce(@values, {%{}, amount}, fn value, {groups, remaining} ->
        count = div(remaining, value)
        next = if count == 0, do: groups, else: Map.put(groups, value, count)
        {next, rem(remaining, value)}
      end)

    {:ok, groups}
  end

  def split(_), do: {:error, :invalid_experience}

  @doc "Pure successor; its owning region must durably commit it before publishing effects."
  def materialize(%Containers{} = containers, key, <<_::256>> = id) do
    with {:ok, _} <- Containers.encode(key, containers),
         {:ok, record} <- fetch_award(containers.pending_awards, id),
         true <- owned?(key, record.position) do
      case Map.fetch(containers.cooking_orbs, id) do
        {:ok, _} ->
          {:ok, containers, :already_materialized}

        :error ->
          next = Map.put(containers.cooking_orbs, id, records(id, record))
          successor = %{containers | cooking_orbs: next}

          # The orb ledger has its own bound, but shares the whole snapshot's byte
          # budget with slots/receipts/awards. Refuse before returning a proposal
          # that its leased writer could not commit.
          case Containers.encode(key, successor) do
            {:ok, _} -> {:ok, successor, :materialized}
            {:error, _} -> {:error, :cooking_orb_capacity}
          end
      end
    else
      false -> {:error, :xp_orb_handoff_required}
      error -> error
    end
  end

  def materialize(_, _, _), do: invalid()

  # This pre-pickup ledger is immutable: each marked award has exactly its native
  # denomination histogram, including an empty record set for zero XP. A later
  # pickup protocol must durably account for consumption before relaxing this check.
  def encode(ledger, key, awards)
      when is_map(ledger) and map_size(ledger) <= @max_awards and is_map(awards) and
             map_size(awards) <= @max_awards do
    parts =
      ledger
      |> Enum.sort()
      |> Enum.map(fn {<<_::256>> = id, orbs} ->
        award = Map.fetch!(awards, id)
        true = owned?(key, award.position)
        true = orbs === records(id, award)

        entries =
          orbs
          |> Enum.sort()
          |> Enum.map(fn {uuid, %{value: value, count: count, position: {x, y, z}}} ->
            <<uuid::binary-size(16), value::16, count::32, x::float-64, y::float-64, z::float-64>>
          end)

        [<<id::binary, map_size(orbs)>>, entries]
      end)

    bytes = IO.iodata_to_binary([<<map_size(ledger)::16>>, parts])
    true = byte_size(bytes) <= @max_bytes
    {:ok, bytes}
  rescue
    _ -> invalid()
  end

  def encode(_, _, _), do: invalid()

  def decode(bytes, key, awards) when is_binary(bytes) and byte_size(bytes) in 2..@max_bytes do
    <<count::16, body::binary>> = bytes
    true = count <= @max_awards
    {ledger, <<>>} = take_awards(body, count, %{})
    {:ok, ^bytes} = encode(ledger, key, awards)
    {:ok, ledger}
  rescue
    _ -> invalid()
  end

  def decode(_, _, _), do: invalid()

  @doc "Derive frozen creation records from a validated immutable award decision."
  def records(id, %{position: position, award: %{recipes: recipes}}) do
    # The furnace awards each recipe separately. Splitting their sum would change
    # denominations (for example, XP 3 + 4 becomes 3,3,1, never one value-7 orb).
    groups =
      Enum.reduce(recipes, %{}, fn row, groups ->
        {:ok, split} = split(row.experience)
        Map.merge(groups, split, fn _, a, b -> a + b end)
      end)

    Map.new(groups, fn {value, count} ->
      <<a::48, _::4, b::12, _::2, c::62, _::128>> =
        :crypto.hash(:sha256, ["VMCCOOKORB", id, <<value::16>>])

      uuid = <<a::48, 8::4, b::12, 2::2, c::62>>
      {uuid, %{position: position, value: value, count: count}}
    end)
  end

  defp take_awards(body, 0, ledger), do: {ledger, body}

  defp take_awards(<<id::binary-size(32), count, body::binary>>, left, ledger)
       when count <= 11 do
    false = Map.has_key?(ledger, id)
    {records, rest} = take_records(body, count, %{})
    take_awards(rest, left - 1, Map.put(ledger, id, records))
  end

  defp take_records(body, 0, records), do: {records, body}

  defp take_records(
         <<uuid::binary-size(16), value::16, count::32, x::float-64, y::float-64, z::float-64,
           rest::binary>>,
         left,
         records
       ) do
    false = Map.has_key?(records, uuid)
    record = %{value: value, count: count, position: {x, y, z}}
    take_records(rest, left - 1, Map.put(records, uuid, record))
  end

  defp fetch_award(awards, id) do
    case Map.fetch(awards, id) do
      :error -> {:error, :unknown_cooking_award}
      found -> found
    end
  end

  defp owned?(key, {x, _, z}) do
    Valimc.World.region_key(Valimc.World.chunk_key(floor(x), floor(z))) == key
  end

  defp invalid, do: {:error, :invalid_cooking_orbs}
end
