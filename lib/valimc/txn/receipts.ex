defmodule Valimc.Txn.Receipts do
  @moduledoc """
  Idempotency for every receipt table (VMC-064): `%{source => %{sequence, digest}}`.

  A source's transfers carry increasing sequences. A request older than the
  stored receipt is stale; one at the stored sequence is a duplicate if the
  stored digest records this request's outcome and a conflict otherwise; newer
  requests are new. `{sequence: 0, digest: <<0::256>>}` reserves a slot without
  recording a transfer. Tables stay separate per sequence space; only the rules
  are shared.

  The stored digest depends on the table's scheme, unchanged from the formats
  already on disk:

  - `:plain` stores the request digest; only `:applied` exists.
  - `{:prefix, tag}` stores `sha256(tag, flag, digest)`.
  - `{:suffix, tag}` stores `sha256(tag, digest, flag)`.

  where `flag` is `<<1>>` for applied and `<<0>>` for rejected.
  """

  @max_sequence 18_446_744_073_709_551_615
  @reserved %{sequence: 0, digest: <<0::256>>}

  def max_sequence, do: @max_sequence

  def valid?(%{sequence: 0, digest: <<0::256>>}), do: true

  def valid?(%{sequence: sequence, digest: <<_::256>>}),
    do: is_integer(sequence) and sequence in 1..@max_sequence

  def valid?(_), do: false

  @doc """
  Reserve a slot for `source` before granting it anything; existing slots stay
  exact. Tables are keyed records (VMC-077f), so the number of sources has no
  cap (VMC-077h).
  """
  def reserve(receipts, source)
      when is_map(receipts) and
             ((is_binary(source) and byte_size(source) == 16) or
                (is_tuple(source) and tuple_size(source) == 2)) do
    case Map.fetch(receipts, source) do
      {:ok, receipt} ->
        if valid?(receipt),
          do: {:ok, receipts, :existing},
          else: {:error, :invalid_receipt_reservation}

      :error ->
        {:ok, Map.put(receipts, source, @reserved), :reserved}
    end
  end

  def reserve(_, _, _), do: {:error, :invalid_receipt_reservation}

  @doc """
  Classify a request against its source's receipt: `:new`, `{:duplicate,
  :already_applied | :already_rejected}`, or `{:error, :stale_transfer |
  :transfer_conflict}`.
  """
  def classify(receipts, source, sequence, digest, scheme) do
    case receipts[source] do
      %{sequence: prior} when sequence < prior ->
        {:error, :stale_transfer}

      %{sequence: ^sequence, digest: stored} ->
        case decode(scheme, digest, stored) do
          :applied -> {:duplicate, :already_applied}
          :rejected -> {:duplicate, :already_rejected}
          :conflict -> {:error, :transfer_conflict}
        end

      _ ->
        :new
    end
  end

  @doc "Record the outcome of a new request."
  def record(receipts, source, sequence, digest, scheme, result),
    do: Map.put(receipts, source, %{sequence: sequence, digest: stored(scheme, digest, result)})

  @doc "What a durable receipt proves about one request (the source's destination proof)."
  def outcome(%{sequence: sequence, digest: stored}, sequence, digest, scheme) do
    case decode(scheme, digest, stored) do
      :conflict -> {:error, :transfer_conflict}
      result -> {:ok, result}
    end
  end

  def outcome(%{sequence: _}, _, _, _), do: {:error, :stale_transfer}
  def outcome(_, _, _, _), do: {:error, :transfer_conflict}

  @doc "The digest a receipt stores for `result`."
  def stored(:plain, digest, :applied), do: digest

  def stored({:prefix, tag}, <<_::256>> = digest, result) when result in [:applied, :rejected],
    do: :crypto.hash(:sha256, [tag, flag(result), digest])

  def stored({:suffix, tag}, <<_::256>> = digest, result) when result in [:applied, :rejected],
    do: :crypto.hash(:sha256, [tag, digest, flag(result)])

  defp decode(:plain, digest, digest), do: :applied
  defp decode(:plain, _, _), do: :conflict

  defp decode(scheme, digest, stored) do
    cond do
      stored == stored(scheme, digest, :applied) -> :applied
      stored == stored(scheme, digest, :rejected) -> :rejected
      true -> :conflict
    end
  end

  defp flag(:applied), do: <<1>>
  defp flag(:rejected), do: <<0>>
end
