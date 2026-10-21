defmodule Valimc.World.Tickets do
  @moduledoc """
  A region owner's chunk tickets (VMC-077e), after vanilla 26.3's `TicketType`.

  Each holder process holds at most one ticket of each type over chunks of the
  region. A ticket with a timeout lasts that many game ticks; one without lasts
  until withdrawn or until its holder exits (the owner monitors it). Loading tickets want their chunks
  generated, nearest to the ticket's center first (`RegionGeneration`);
  simulation tickets make their chunks tick: scheduled and random block ticks,
  and the region's items, cooking and orbs while any chunk ticks. A fresh owner
  holds a one-tick `:unknown` ticket of its own admission. A region without
  tickets and without work in flight unloads after a delay (`RegionData`).

  | Type | Timeout (ticks) | Loads | Simulates |
  |---|---|---|---|
  | `:player_loading` (view) | none | yes | no |
  | `:player_simulation` | none | no | yes |
  | `:forced` | none | yes | yes |
  | `:portal` | 300 | yes | yes |
  | `:post_teleport` | 5 | yes | yes |
  | `:player_spawn` | 20 | yes | no |
  | `:spawn_search` | 1 | yes | no |
  | `:unknown` | 1 | yes | no |

  `:post_teleport` is the pre-26 vanilla type (26.3 relies on the player's
  loading ticket after the move); here it keeps a teleport's destination loaded
  until the player's view ticket arrives.
  """

  @types %{
    player_loading: {nil, true, false},
    player_simulation: {nil, false, true},
    forced: {nil, true, true},
    portal: {300, true, true},
    post_teleport: {5, true, true},
    player_spawn: {20, true, false},
    spawn_search: {1, true, false},
    unknown: {1, true, false}
  }

  defstruct entries: %{}, monitors: %{}, simulated: MapSet.new()

  def types, do: Map.keys(@types)

  @doc "The tickets of a fresh owner at game tick `tick`: its admission's `:unknown` one."
  def new(tick),
    do: %__MODULE__{
      entries: %{
        {:admission, :unknown} => %{center: nil, chunks: MapSet.new(), expires: tick + 1}
      }
    }

  @doc """
  `holder` (a pid) now holds a `type` ticket over `chunks` (around `center`),
  replacing its previous one of that type; an empty list withdraws it.
  """
  def put(%__MODULE__{} = tickets, holder, type, center, chunks, tick)
      when is_pid(holder) and is_map_key(@types, type) and is_list(chunks) do
    tickets =
      case chunks do
        [] ->
          %{tickets | entries: Map.delete(tickets.entries, {holder, type})}

        _ ->
          {timeout, _, _} = @types[type]

          entry = %{
            center: center,
            chunks: MapSet.new(chunks),
            expires: timeout && tick + timeout
          }

          tickets = %{tickets | entries: Map.put(tickets.entries, {holder, type}, entry)}
          if timeout, do: tickets, else: monitor(tickets, holder)
      end

    tickets |> demonitor_unused() |> simulated(type)
  end

  @doc "A monitored holder went down: `{:ok, tickets}` without its tickets, or `:error`."
  def down(%__MODULE__{} = tickets, monitor) do
    case Enum.find(tickets.monitors, fn {_, ref} -> ref == monitor end) do
      {holder, _} ->
        entries =
          Map.reject(tickets.entries, fn {{h, _}, entry} ->
            h == holder and entry.expires == nil
          end)

        tickets = %{tickets | entries: entries, monitors: Map.delete(tickets.monitors, holder)}
        {:ok, %{tickets | simulated: simulating(entries)}}

      nil ->
        :error
    end
  end

  @doc "Drop the tickets whose timeout ended by game tick `tick`."
  def expire(%__MODULE__{} = tickets, tick) do
    entries =
      Map.reject(tickets.entries, fn {_, entry} -> entry.expires && entry.expires <= tick end)

    if map_size(entries) == map_size(tickets.entries),
      do: tickets,
      else: %{demonitor_unused(%{tickets | entries: entries}) | simulated: simulating(entries)}
  end

  def empty?(%__MODULE__{entries: entries}), do: map_size(entries) == 0

  @doc "Whether any chunk ticks."
  def simulating?(%__MODULE__{simulated: simulated}), do: MapSet.size(simulated) > 0

  def simulated?(%__MODULE__{simulated: simulated}, chunk), do: MapSet.member?(simulated, chunk)

  @doc "The loading tickets as `{center, chunks}` (a generation's wants)."
  def loading(%__MODULE__{entries: entries}) do
    for {{_, type}, entry} <- entries, elem(@types[type], 1), do: {entry.center, entry.chunks}
  end

  defp monitor(tickets, holder) do
    if Map.has_key?(tickets.monitors, holder),
      do: tickets,
      else: %{tickets | monitors: Map.put(tickets.monitors, holder, Process.monitor(holder))}
  end

  defp demonitor_unused(tickets) do
    holders = for {{h, _}, %{expires: nil}} <- tickets.entries, into: MapSet.new(), do: h

    {kept, gone} = Map.split_with(tickets.monitors, fn {h, _} -> MapSet.member?(holders, h) end)
    for {_, ref} <- gone, do: Process.demonitor(ref, [:flush])
    %{tickets | monitors: kept}
  end

  defp simulated(tickets, type) do
    if elem(@types[type], 2),
      do: %{tickets | simulated: simulating(tickets.entries)},
      else: tickets
  end

  defp simulating(entries) do
    for {{_, type}, entry} <- entries,
        elem(@types[type], 2),
        chunk <- entry.chunks,
        into: MapSet.new(),
        do: chunk
  end
end
