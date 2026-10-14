defmodule Valimc.Physics.CollisionContext do
  @moduledoc "Pure geometry context. Simulation owners must supply these facts, never raw client flags."
  @epsilon 9.999999747378752e-6
  defstruct kind: :empty, bottom: 0.0, descending: false, placement: false

  def empty, do: %__MODULE__{}

  def entity(bottom, descending \\ false, placement \\ false)

  def entity(bottom, descending, placement)
      when is_number(bottom) and is_boolean(descending) and is_boolean(placement) do
    context = %__MODULE__{
      kind: :entity,
      bottom: bottom,
      descending: descending,
      placement: placement
    }

    unless valid?(context), do: raise(ArgumentError, "invalid collision context")
    %{context | bottom: bottom * 1.0}
  end

  def entity(_, _, _), do: raise(ArgumentError, "invalid collision context")

  def valid?(%__MODULE__{kind: :empty, bottom: bottom, descending: false, placement: false}),
    do: is_float(bottom) and bottom == 0.0

  def valid?(%__MODULE__{
        kind: :entity,
        bottom: bottom,
        descending: descending,
        placement: placement
      }),
      do:
        is_number(bottom) and abs(bottom) <= 60_000_000 and is_boolean(descending) and
          is_boolean(placement)

  def valid?(_), do: false

  # Native empty context answers the supplied fallback; entity context ignores it.
  def above?(%__MODULE__{kind: :empty}, _shape_top, _block_y, fallback), do: fallback

  def above?(%__MODULE__{kind: :entity, bottom: bottom}, shape_top, block_y, _fallback),
    do: bottom > block_y + shape_top - @epsilon
end
