defmodule Valimc.Physics.MotionBlocks do
  @moduledoc "Shared immutable scalar motion facts for every pinned block state."
  import Bitwise
  @path Path.expand("../../../priv/physics/motion_blocks.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @count @facts["state_count"]
  unless Valimc.Version.stamped?(@facts) and
           @count == Valimc.Protocol.Data.block_state_count(),
         do: raise("Wrong motion block catalog version")

  @properties Enum.map(@facts["properties"], fn f ->
                unless map_size(f) == 7 and is_boolean(f["suppresses_bounce"]) and
                         is_boolean(f["support_holds_y"]) and
                         is_boolean(f["fluid_empty"]) and
                         Enum.all?(["friction", "bounciness"], fn k ->
                           is_number(f[k]) and f[k] >= 0 and f[k] <= 1
                         end) and
                         Enum.all?(["speed_factor", "jump_factor"], fn k ->
                           is_number(f[k]) and f[k] >= 0 and f[k] <= 4
                         end),
                       do: raise("Invalid motion block properties")

                %{
                  friction: f["friction"],
                  speed_factor: f["speed_factor"],
                  jump_factor: f["jump_factor"],
                  bounciness: f["bounciness"],
                  suppresses_bounce: f["suppresses_bounce"],
                  fluid_empty: f["fluid_empty"],
                  support_holds_y: f["support_holds_y"]
                }
              end)
              |> List.to_tuple()
  @states Base.decode16!(@facts["states"], case: :lower)
  @fences MapSet.new(@facts["fence_states"])
  @speed_overrides MapSet.new(@facts["speed_override_states"])
  unless MapSet.size(@fences) > 0 and MapSet.size(@speed_overrides) == 18 and
           Enum.all?([@fences, @speed_overrides], fn ids ->
             Enum.all?(ids, &(is_integer(&1) and &1 in 0..(@count - 1)))
           end),
         do: raise("Invalid contextual material states")

  unless tuple_size(@properties) == 10 and byte_size(@states) == div(@count + 1, 2) and
           (rem(@count, 2) == 0 or (:binary.last(@states) &&& 15) == 0) and
           Enum.all?(0..(@count - 1), fn id ->
             byte = :binary.at(@states, div(id, 2))
             index = if rem(id, 2) == 0, do: byte >>> 4, else: byte &&& 15
             index < tuple_size(@properties)
           end),
         do: raise("Incomplete motion block catalog")

  def state_count, do: @count

  def fetch(id) when is_integer(id) and id >= 0 and id < @count do
    byte = :binary.at(@states, div(id, 2))
    index = if rem(id, 2) == 0, do: byte >>> 4, else: byte &&& 15
    {:ok, elem(@properties, index)}
  end

  def fetch(_), do: {:error, :unknown_block_state}

  def uses_own_speed?(id), do: MapSet.member?(@speed_overrides, id)
  def fence?(id), do: MapSet.member?(@fences, id)
end
