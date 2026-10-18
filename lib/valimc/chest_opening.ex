defmodule Valimc.ChestOpening do
  @moduledoc "Pinned single-chest provider eligibility; actor admission/locks/loot are separate."
  import Bitwise
  alias Valimc.ChestAccess
  @path Path.expand("../../priv/protocol/chest_opening.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count @facts["state_count"]
  @mask Base.decode64!(@facts["blocked_above_bits"])
  if @count != Valimc.Protocol.Data.block_state_count() or byte_size(@mask) != div(@count + 7, 8),
    do: raise("Wrong chest opening facts")

  def obstructed?(above, false) when is_integer(above) and above >= 0 and above < @count,
    do: (:binary.at(@mask, above >>> 3) &&& 1 <<< (above &&& 7)) != 0

  def obstructed?(_, _), do: true

  def provider?(block, true, above, sitting_cat) when is_boolean(sitting_cat),
    do: ChestAccess.single?(block) and not obstructed?(above, sitting_cat)

  def provider?(_, _, _, _), do: false
end
