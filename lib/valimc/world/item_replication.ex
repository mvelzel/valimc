defmodule Valimc.World.ItemReplication do
  @moduledoc "Bounded observer-local item updates; position and metadata revisions are independent."
  alias Valimc.Protocol.EntityPackets
  alias Valimc.World.Items
  defstruct tracked: %{}, cursor: 0
  @max_visible 1024
  @max_changes 64
  @max_bytes 262_144

  def new, do: %__MODULE__{}
  def max_visible, do: @max_visible

  def reconcile(state, desired) when map_size(desired) <= @max_visible do
    removed =
      for {id, {epoch, _}} <- state.tracked,
          not Map.has_key?(desired, id) or desired[id].epoch != epoch,
          do: id

    removal =
      if removed == [], do: [], else: [binary_packet(EntityPackets.remove(Enum.sort(removed)))]

    retained = Map.drop(state.tracked, removed)
    ids = desired |> Map.keys() |> Enum.sort()
    {earlier, later} = Enum.split_while(ids, &(&1 <= state.cursor))
    bytes = Enum.reduce(removal, 0, &(Items.packet_bytes(&1) + &2))

    {tracked, cursor, packets, _bytes, _changes} =
      Enum.reduce_while(later ++ earlier, {retained, state.cursor, [], bytes, 0}, fn id, acc ->
        {tracked, _cursor, packets, bytes, changes} = acc
        view = desired[id]
        version = {view.epoch, {view.metadata_revision, view.motion_revision}}

        delta =
          case tracked[id] do
            nil ->
              [view.spawn, view.metadata]

            ^version ->
              []

            {_, {metadata_revision, motion_revision}} ->
              moved =
                if motion_revision == view.motion_revision,
                  do: [],
                  else: [view.position, view.motion]

              moved ++
                if(metadata_revision == view.metadata_revision, do: [], else: [view.metadata])
          end

        cost = Enum.reduce(delta, 0, &(Items.packet_bytes(&1) + &2))

        if delta != [] and (changes >= @max_changes or bytes + cost > @max_bytes) do
          {:halt, acc}
        else
          next =
            {Map.put(tracked, id, version), id, Enum.reverse(delta, packets), bytes + cost,
             changes + if(delta == [], do: 0, else: 1)}

          {:cont, next}
        end
      end)

    {%{state | tracked: tracked, cursor: cursor}, removal ++ Enum.reverse(packets)}
  end

  defp binary_packet({id, payload}), do: {id, IO.iodata_to_binary(payload)}
end
