defmodule Valimc.World.PendingCookingAwards do
  @moduledoc "Bounded immutable cooking decisions, persisted with containers before any XP/recipe effect."
  alias Valimc.CookingAwards
  alias Valimc.World.ContainerTransfers
  @path Path.expand("../../../priv/crafting/cooking.json", __DIR__)
  @external_resource @path
  @recipes JSON.decode!(File.read!(@path))["recipes"]
           |> Enum.map(& &1["recipe"])
           |> List.to_tuple()
  @ids @recipes |> Tuple.to_list() |> Enum.with_index() |> Map.new()
  @max_awards 256
  @max_bytes 524_288
  @max_record 85 + 107 * 14
  @no_draw 16_777_216
  @max_sequence 18_446_744_073_709_551_615
  def max_awards, do: @max_awards
  def max_bytes, do: @max_bytes

  def put(awards, key, source, sequence, digest, {x, y, z}, award)
      when is_map(awards) and map_size(awards) <= @max_awards and
             is_number(x) and is_number(y) and is_number(z) do
    record = %{
      source: source,
      sequence: sequence,
      digest: digest,
      position: {x * 1.0, y * 1.0, z * 1.0},
      award: award
    }

    id = identity(key, source, sequence, digest)
    _bytes = record_bytes(record)

    cond do
      Map.get(awards, id) == record ->
        {:ok, awards, id}

      Map.has_key?(awards, id) or
          Enum.any?(awards, fn {_, prior} ->
            prior.source == source and prior.sequence == sequence
          end) ->
        {:error, :cooking_award_conflict}

      map_size(awards) == @max_awards ->
        {:error, :cooking_award_limit}

      true ->
        {:ok, Map.put(awards, id, record), id}
    end
  rescue
    _ -> invalid()
  end

  def put(_, _, _, _, _, _, _), do: invalid()

  def encode(key, awards, receipts) when is_map(awards) and map_size(awards) <= @max_awards do
    sources = Enum.map(awards, fn {_, r} -> {r.source, r.sequence} end)
    true = length(Enum.uniq(sources)) == length(sources)

    parts =
      awards
      |> Enum.sort()
      |> Enum.map(fn {id, record} ->
        ^id = identity(key, record.source, record.sequence, record.digest)
        true = receipt?(receipts[record.source], record)
        bytes = record_bytes(record)
        <<id::binary-size(32), byte_size(bytes)::16, bytes::binary>>
      end)

    bytes = IO.iodata_to_binary([<<map_size(awards)::16>>, parts])
    true = byte_size(bytes) <= @max_bytes
    {:ok, bytes}
  rescue
    _ -> invalid()
  end

  def encode(_, _, _), do: invalid()

  def decode(bytes, key, receipts)
      when is_binary(bytes) and byte_size(bytes) in 2..@max_bytes do
    <<count::16, body::binary>> = bytes
    true = count <= @max_awards
    {awards, <<>>} = take(body, count, %{})
    {:ok, ^bytes} = encode(key, awards, receipts)
    {:ok, awards}
  rescue
    _ -> invalid()
  end

  def decode(_, _, _), do: invalid()

  defp identity({rx, rz}, <<_::128>> = source, sequence, <<_::256>> = digest)
       when is_integer(rx) and rx in -2_147_483_648..2_147_483_647 and
              is_integer(rz) and rz in -2_147_483_648..2_147_483_647 and
              is_integer(sequence) and sequence in 1..@max_sequence do
    :crypto.hash(:sha256, [
      "VMCCOOKAWARD",
      <<rx::signed-32, rz::signed-32>>,
      source,
      <<sequence::64>>,
      digest
    ])
  end

  defp record_bytes(
         %{
           source: <<_::128>> = source,
           sequence: sequence,
           digest: <<_::256>> = digest,
           position: {x, y, z},
           award: award
         } = record
       )
       when map_size(record) == 5 and is_integer(sequence) and sequence in 1..@max_sequence and
              is_float(x) and abs(x) <= 29_999_984 and is_float(z) and abs(z) <= 29_999_984 and
              is_float(y) and abs(y) <= 1_000_000 do
    %{recipes: recipes, experience: total, draws_used: draws} = award
    true = is_list(recipes)
    rows = Enum.take(recipes, 108)
    true = length(rows) in 1..107
    uses = Map.new(rows, &{&1.recipe, &1.uses})
    true = map_size(uses) == length(rows)
    {:ok, ^award} = CookingAwards.plan(uses, draws)

    parts =
      Enum.map(rows, fn row ->
        index = Map.fetch!(@ids, row.recipe)
        draw = Map.get(draws, row.recipe, @no_draw)
        <<index::16, row.uses::32, row.experience::32, draw::32>>
      end)

    IO.iodata_to_binary([
      <<source::binary, sequence::64, digest::binary, x::float-64, y::float-64, z::float-64,
        total::32, length(rows)>>,
      parts
    ])
  end

  defp receipt?(%{sequence: sequence, digest: <<_::256>> = digest}, record)
       when is_integer(sequence) and sequence == record.sequence,
       do: digest == ContainerTransfers.result_digest(record.digest, :applied)

  defp receipt?(%{sequence: sequence, digest: <<_::256>>}, record)
       when is_integer(sequence) and sequence > record.sequence and sequence <= @max_sequence,
       do: true

  defp receipt?(_, _), do: false

  defp take(body, 0, awards), do: {awards, body}

  defp take(<<id::binary-size(32), size::16, rest::binary>>, count, awards)
       when size in 99..@max_record do
    false = Map.has_key?(awards, id)
    <<bytes::binary-size(^size), rest::binary>> = rest

    <<source::binary-size(16), sequence::64, digest::binary-size(32), x::float-64, y::float-64,
      z::float-64, total::32, recipe_count, rows::binary>> = bytes

    true = recipe_count in 1..107 and byte_size(rows) == recipe_count * 14

    {recipes, draws} =
      for(<<index::16, uses::32, amount::32, draw::32 <- rows>>,
        do: {elem(@recipes, index), uses, amount, draw}
      )
      |> Enum.map_reduce(%{}, fn {recipe, uses, amount, draw}, acc ->
        next = if draw == @no_draw, do: acc, else: Map.put(acc, recipe, draw)
        {%{recipe: recipe, uses: uses, experience: amount}, next}
      end)

    record = %{
      source: source,
      sequence: sequence,
      digest: digest,
      position: {x, y, z},
      award: %{recipes: recipes, experience: total, draws_used: draws}
    }

    take(rest, count - 1, Map.put(awards, id, record))
  end

  defp invalid, do: {:error, :invalid_pending_cooking_awards}
end
