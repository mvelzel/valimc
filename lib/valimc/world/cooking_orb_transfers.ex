defmodule Valimc.World.CookingOrbTransfers do
  @moduledoc "Bounded remote spawn intents and immutable adoption receipts; persist before delivery/publication."
  alias Valimc.World.{Containers, CookingOrbs, PendingCookingAwards}
  @max_awards 256
  @max_sequence 18_446_744_073_709_551_615
  @max_request 16 + PendingCookingAwards.max_record_bytes()
  @max_bytes 12 + @max_awards * (33 + 2 + @max_request)
  def new, do: %{revision: 0, outgoing: %{}, incoming: %{}}
  def max_request_bytes, do: @max_request

  @doc "Reserve routing in source storage before sending the returned request."
  def prepare(%Containers{} = state, key, id) do
    with {:ok, _} <- Containers.encode(key, state),
         {:ok, award} <- Map.fetch(state.pending_awards, id),
         false <- Map.has_key?(state.cooking_orbs, id),
         request = %{source: key, destination: owner(award.position), id: id, award: award},
         {:ok, _} <- encode_request(request) do
      case state.orb_transfers.outgoing[id] do
        nil ->
          transfers = state.orb_transfers

          next = %{
            transfers
            | revision: transfers.revision + 1,
              outgoing: Map.put(transfers.outgoing, id, :pending)
          }

          successor(state, key, next, {request, :prepared})

        status ->
          {:ok, state, request,
           if(status == :pending, do: :already_prepared, else: :already_delivered)}
      end
    else
      :error -> {:error, :unknown_cooking_award}
      true -> {:error, :cooking_orb_already_local}
      _ -> invalid()
    end
  end

  def prepare(_, _, _), do: invalid()

  @doc "Reconstruct delivery only from a stored source intent, including after recovery."
  def request(%Containers{} = state, key, id) do
    with {:ok, _} <- Containers.encode(key, state),
         status when status in [:pending, :delivered] <- state.orb_transfers.outgoing[id],
         {:ok, award} <- Map.fetch(state.pending_awards, id),
         request = %{source: key, destination: owner(award.position), id: id, award: award},
         {:ok, _} <- encode_request(request) do
      {:ok, request}
    else
      _ -> {:error, :missing_cooking_orb_intent}
    end
  end

  def request(_, _, _), do: invalid()

  @doc "Propose adoption and its replay receipt together; no second effect on retry."
  def accept(%Containers{} = state, key, %{destination: key, id: id} = request) do
    with {:ok, _} <- Containers.encode(key, state),
         {:ok, _} <- encode_request(request) do
      case state.orb_transfers.incoming[id] do
        ^request ->
          {:ok, state, :already_applied}

        nil ->
          transfers = state.orb_transfers

          if Enum.any?(transfers.incoming, fn {_, prior} -> origin(prior) == origin(request) end) do
            {:error, :cooking_orb_transfer_conflict}
          else
            next = %{
              transfers
              | revision: transfers.revision + 1,
                incoming: Map.put(transfers.incoming, id, request)
            }

            successor(state, key, next, :applied)
          end

        _ ->
          {:error, :cooking_orb_transfer_conflict}
      end
    else
      _ -> invalid()
    end
  end

  def accept(_, _, _), do: invalid()

  @doc "Settle only matching durable adoption; retain the recipe obligation and replay tombstone."
  def acknowledge(%Containers{} = state, key, id, digest) do
    with {:ok, request} <- request(state, key, id),
         {:ok, ^digest} <- digest(request) do
      case state.orb_transfers.outgoing[id] do
        :delivered ->
          {:ok, state, :already_delivered}

        :pending ->
          transfers = state.orb_transfers

          next = %{
            transfers
            | revision: transfers.revision + 1,
              outgoing: Map.put(transfers.outgoing, id, :delivered)
          }

          successor(state, key, next, :delivered)
      end
    else
      _ -> {:error, :stale_cooking_orb_acknowledgement}
    end
  end

  def acknowledge(_, _, _, _), do: invalid()

  defp successor(state, key, transfers, result) do
    next = %{state | orb_transfers: transfers}

    case Containers.encode(key, next) do
      {:ok, _} ->
        case result do
          {request, status} -> {:ok, next, request, status}
          status -> {:ok, next, status}
        end

      _ ->
        {:error, :cooking_orb_transfer_capacity}
    end
  end

  def digest(request) do
    with {:ok, bytes} <- encode_request(request),
         do: {:ok, :crypto.hash(:sha256, ["VMCCOOKORBXFER", <<1>>, bytes])}
  end

  def records(request) do
    with {:ok, _} <- encode_request(request),
         do: {:ok, CookingOrbs.records(request.id, request.award)}
  end

  def encode_request(
        %{source: {sx, sz} = source, destination: {dx, dz} = dest, id: id, award: award} = request
      )
      when map_size(request) == 4 do
    true = region?(source) and region?(dest) and source != dest
    true = owner(award.position) == dest
    {:ok, bytes} = PendingCookingAwards.encode_record(source, id, award)
    {:ok, <<sx::signed-32, sz::signed-32, dx::signed-32, dz::signed-32, bytes::binary>>}
  rescue
    _ -> invalid()
  end

  def encode_request(_), do: invalid()

  def decode_request(bytes) when is_binary(bytes) and byte_size(bytes) in 149..@max_request do
    <<sx::signed-32, sz::signed-32, dx::signed-32, dz::signed-32, record::binary>> = bytes
    {:ok, id, award} = PendingCookingAwards.decode_record(record, {sx, sz})
    request = %{source: {sx, sz}, destination: {dx, dz}, id: id, award: award}
    {:ok, ^bytes} = encode_request(request)
    {:ok, request}
  rescue
    _ -> invalid()
  end

  def decode_request(_), do: invalid()

  def encode(
        %{revision: revision, outgoing: outgoing, incoming: incoming} = state,
        key,
        awards,
        local
      )
      when map_size(state) == 3 do
    true = region?(key) and is_map(outgoing) and is_map(incoming)

    true =
      map_size(outgoing) <= @max_awards and map_size(incoming) + map_size(local) <= @max_awards

    true = is_integer(revision) and revision in 0..@max_sequence
    origins = Enum.map(incoming, fn {_, request} -> origin(request) end)
    true = length(Enum.uniq(origins)) == length(origins)

    true =
      revision ==
        map_size(outgoing) + map_size(incoming) +
          Enum.count(outgoing, fn {_, status} -> status == :delivered end)

    routes =
      Enum.map(Enum.sort(outgoing), fn {<<_::256>> = id, status} ->
        true = status in [:pending, :delivered] and not Map.has_key?(local, id)
        award = Map.fetch!(awards, id)

        {:ok, _} =
          encode_request(%{source: key, destination: owner(award.position), id: id, award: award})

        <<id::binary, if(status == :pending, do: 0, else: 1)>>
      end)

    imports =
      Enum.map(Enum.sort(incoming), fn {id, request} ->
        true = request.id === id and request.destination == key
        true = not Map.has_key?(awards, id) and not Map.has_key?(local, id)
        {:ok, bytes} = encode_request(request)
        <<byte_size(bytes)::16, bytes::binary>>
      end)

    bytes =
      IO.iodata_to_binary([
        <<revision::64, map_size(outgoing)::16, map_size(incoming)::16>>,
        routes,
        imports
      ])

    true = byte_size(bytes) <= @max_bytes
    {:ok, bytes}
  rescue
    _ -> invalid()
  end

  def encode(_, _, _, _), do: invalid()

  def decode(bytes, key, awards, local)
      when is_binary(bytes) and byte_size(bytes) in 12..@max_bytes do
    <<revision::64, routes::16, imports::16, body::binary>> = bytes
    true = routes <= @max_awards and imports <= @max_awards
    {outgoing, body} = take_routes(body, routes, %{})
    {incoming, <<>>} = take_imports(body, imports, %{})
    state = %{revision: revision, outgoing: outgoing, incoming: incoming}
    {:ok, ^bytes} = encode(state, key, awards, local)
    {:ok, state}
  rescue
    _ -> invalid()
  end

  def decode(_, _, _, _), do: invalid()

  defp take_routes(body, 0, acc), do: {acc, body}

  defp take_routes(<<id::binary-size(32), status, body::binary>>, count, acc) do
    false = Map.has_key?(acc, id)

    status =
      case status do
        0 -> :pending
        1 -> :delivered
      end

    take_routes(body, count - 1, Map.put(acc, id, status))
  end

  defp take_imports(body, 0, acc), do: {acc, body}

  defp take_imports(<<size::16, body::binary>>, count, acc) when size <= @max_request do
    <<bytes::binary-size(^size), body::binary>> = body
    {:ok, request} = decode_request(bytes)
    false = Map.has_key?(acc, request.id)
    take_imports(body, count - 1, Map.put(acc, request.id, request))
  end

  defp owner({x, _, z}), do: Valimc.World.region_key(Valimc.World.chunk_key(x, z))
  defp origin(request), do: {request.source, request.award.source, request.award.sequence}

  defp region?({x, z}),
    do:
      is_integer(x) and is_integer(z) and x in -2_147_483_648..2_147_483_647 and
        z in -2_147_483_648..2_147_483_647

  defp region?(_), do: false
  defp invalid, do: {:error, :invalid_cooking_orb_transfer}
end
