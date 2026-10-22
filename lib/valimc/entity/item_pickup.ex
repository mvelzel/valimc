defmodule Valimc.Entity.ItemPickup do
  @moduledoc "Unmounted native pickup contact from an accepted player body and current owned item."
  alias Valimc.Player.GameMode
  alias Valimc.Data.Box

  def query_box({x0, y0, z0, x1, y1, z1} = box) do
    if Box.valid?(box),
      do: {:ok, {x0 - 1, y0 - 0.5, z0 - 1, x1 + 1, y1 + 0.5, z1 + 1}},
      else: {:error, :invalid_pickup_body}
  end

  def query_box(_), do: {:error, :invalid_pickup_body}

  def contact?(box, {x, y, z}) when is_number(x) and is_number(y) and is_number(z) do
    item = {x - 0.125, y, z - 0.125, x + 0.125, y + 0.25, z + 0.125}

    with {:ok, query} <- query_box(box),
         true <- Box.valid?(item),
         do: Box.intersects?(query, item),
         else: (_ -> false)
  end

  def contact?(_, _), do: false

  def eligible?(
        %{
          uuid: <<_::128>> = uuid,
          box: box,
          game_mode: %GameMode{current: mode},
          health: %{value: hp}
        } = actor,
        %{entity: %{x: x, y: y, z: z}} = entry
      )
      when mode in [:survival, :adventure, :creative] and is_number(hp) and hp > 0 do
    not Map.get(actor, :passenger, false) and
      Map.get(Map.get(entry, :motion, %{}), :pickup_delay, 0) == 0 and
      Map.get(entry, :pickup_target) in [nil, uuid] and contact?(box, {x, y, z})
  rescue
    _ -> false
  end

  def eligible?(_, _), do: false
end
