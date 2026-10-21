defmodule Valimc.Txn.Permits do
  @moduledoc """
  One bounded table of short-lived owner grants for every transfer kind (VMC-064).

  A permit is a token an owner hands a source before it prepares a transfer; the
  destination later consumes it to decide eligibility. Kinds differ only in their
  limit, lifetime, whether a source may hold one at a time, and the positions
  whose edits revoke them. What a grant binds (blocks, an item, a request digest)
  and how a request is checked against it stays in the kind's own module.
  """

  defstruct entries: %{}

  @kinds %{
    pickup: %{
      limit: 128,
      lifetime: 250,
      scaled: true,
      per_source: :pickup_already_pending,
      full: :pickup_permits_full
    },
    container: %{
      limit: 128,
      lifetime: 5000,
      per_source: :container_already_pending,
      full: :container_permits_full
    },
    item_merge: %{
      limit: 8,
      lifetime: 250,
      scaled: true,
      per_source: :item_merge_already_pending,
      full: :item_merge_permits_full
    },
    mining: %{limit: 128, lifetime: 10_000, per_source: nil, full: :mining_permit_limit},
    placement: %{limit: 128, lifetime: 10_000, per_source: nil, full: :placement_permit_limit},
    # A proto owner's chunk locks for finalize transactions (VMC-025d2). They
    # end by the transaction's part or abort; the owner renews them while it
    # asks the coordinator, so the lifetime only bounds a forgotten lock.
    generation: %{limit: 64, lifetime: 3_600_000, per_source: nil, full: :generation_lock_limit},
    # A box edit's cells (VMC-077o), locked from its prepare to its commit or
    # abort; the lifetime only bounds a lock its command abandoned.
    box_edit: %{limit: 16, lifetime: 5000, scaled: true, per_source: nil, full: :box_edits_busy}
  }

  def new, do: %__MODULE__{}

  @doc """
  A kind's lifetime in ms. The short contact grants scale with the issuing owner's
  `owner_call_scale` like its call budgets (VMC-073): 1 in play.
  """
  def lifetime(kind) do
    case @kinds[kind] do
      %{scaled: true, lifetime: ms} -> window(ms)
      %{lifetime: ms} -> ms
    end
  end

  @doc """
  A contact window of `ms` as the calling owner measures it: `ms` in play, scaled by
  `owner_call_scale` in tests (VMC-073). Owners use it for the widest grant they
  accept; a connection passes its player's UUID as `scope` for the grants it issues.
  """
  def window(ms, scope \\ self()), do: ms * Valimc.config(:owner_call_scale, scope)

  @doc "Whether `source` may receive a `kind` permit now (limits and one-per-source)."
  def admit(%__MODULE__{} = permits, kind, source, now) do
    rules = Map.fetch!(@kinds, kind)
    live = for {_, %{kind: ^kind} = e} <- permits.entries, e.expires > now, do: e

    cond do
      rules.per_source && Enum.any?(live, &(&1.source == source)) -> {:error, rules.per_source}
      length(live) >= rules.limit -> {:error, rules.full}
      true -> :ok
    end
  end

  @doc """
  Install a grant under `token` (a fresh random token when `nil`). `positions` are
  the blocks whose edits revoke it; `grant` is the kind's own binding.
  """
  def issue(%__MODULE__{} = permits, kind, token, source, positions, grant, now)
      when is_integer(now) and is_list(positions) do
    token = token || :crypto.strong_rand_bytes(16)
    permits = prune(permits, now)

    with :ok <- admit(permits, kind, source, now),
         false <- Map.has_key?(permits.entries, token) do
      entry = %{
        kind: kind,
        source: source,
        positions: positions,
        grant: grant,
        expires: now + lifetime(kind)
      }

      {:ok, %{permits | entries: Map.put(permits.entries, token, entry)}, token}
    else
      true -> {:error, :permit_collision}
      error -> error
    end
  end

  @doc "The live grant of a `kind` permit."
  def lookup(%__MODULE__{} = permits, kind, token, now) do
    case permits.entries[token] do
      %{kind: ^kind, expires: expires, grant: grant} when expires > now -> {:ok, grant}
      _ -> :error
    end
  end

  @doc """
  Remove a live `kind` permit held by `source` and return its grant (`nil` when
  absent, expired or held by another source). Taking a matching token is
  irreversible even when the request that presented it turns out ineligible.
  """
  def take(%__MODULE__{} = permits, kind, token, source, now) do
    permits = prune(permits, now)

    case permits.entries[token] do
      %{kind: ^kind, source: ^source, grant: grant} ->
        {%{permits | entries: Map.delete(permits.entries, token)}, grant}

      _ ->
        {permits, nil}
    end
  end

  @doc "Extend a still-live permit; expired and revoked tokens never revive."
  def renew(%__MODULE__{} = permits, kind, token, now) do
    case permits.entries[token] do
      %{kind: ^kind, expires: expires} = entry when expires > now ->
        entry = %{entry | expires: now + lifetime(kind)}
        {:ok, %{permits | entries: Map.put(permits.entries, token, entry)}, entry.grant}

      _ ->
        :error
    end
  end

  @doc "Drop a permit if `source` holds it (any source when `nil`)."
  def release(%__MODULE__{} = permits, token, source \\ nil) do
    case permits.entries[token] do
      %{source: held} when source == nil or held == source ->
        %{permits | entries: Map.delete(permits.entries, token)}

      _ ->
        permits
    end
  end

  @doc """
  Whether a live box-edit lock other than `token` holds any of `positions`:
  writes to locked cells are refused until the lock's commit or abort.
  """
  def locked?(%__MODULE__{} = permits, positions, token \\ nil, now) do
    Enum.any?(permits.entries, fn
      {held, %{kind: :box_edit, expires: expires, grant: %{cells: cells}}}
      when held != token and expires > now ->
        Enum.any?(positions, &MapSet.member?(cells, &1))

      _ ->
        false
    end)
  end

  @doc """
  Revoke permits bound to any edited position, except the listed kinds. Box
  edit locks are never revoked: edits to their cells are refused instead.
  """
  def invalidate(%__MODULE__{} = permits, edits, except \\ []) when is_map(edits) do
    if map_size(edits) == 0 do
      permits
    else
      entries =
        Map.reject(permits.entries, fn {_, entry} ->
          entry.kind not in [:box_edit | except] and
            Enum.any?(entry.positions, &Map.has_key?(edits, &1))
        end)

      %{permits | entries: entries}
    end
  end

  defp prune(permits, now),
    do: %{permits | entries: Map.reject(permits.entries, fn {_, e} -> e.expires <= now end)}
end
