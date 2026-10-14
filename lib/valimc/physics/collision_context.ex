defmodule Valimc.Physics.CollisionContext do
  @moduledoc "Pure geometry context. Simulation owners must supply these facts, never raw client flags."
  @epsilon 9.999999747378752e-6
  defstruct kind: :empty,
            bottom: 0.0,
            descending: false,
            placement: false,
            entity_present: false,
            fall_distance: 0.0,
            falling_block: false,
            powder_snow_walkable: false,
            piston_movement: nil

  def empty, do: %__MODULE__{}

  def with_piston_movement(context, direction) do
    unless valid?(context) and movement?(direction),
      do: raise(ArgumentError, "invalid movement exclusion")

    %{context | piston_movement: direction}
  end

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

  # Observations of the authoritative entity; the geometric constructor alone
  # also represents native contexts whose entity reference is absent.
  def with_entity(context, fall_distance, falling_block, powder_snow_walkable)
      when is_number(fall_distance) and is_boolean(falling_block) and
             is_boolean(powder_snow_walkable) do
    unless valid?(context) and context.kind == :entity,
      do: raise(ArgumentError, "entity context required")

    result = %{
      context
      | entity_present: true,
        fall_distance: fall_distance,
        falling_block: falling_block,
        powder_snow_walkable: powder_snow_walkable
    }

    unless valid?(result), do: raise(ArgumentError, "invalid entity collision facts")
    %{result | fall_distance: fall_distance * 1.0}
  end

  def with_entity(_, _, _, _), do: raise(ArgumentError, "invalid entity collision facts")

  def valid?(%__MODULE__{kind: :empty, bottom: bottom, descending: false, placement: false} = c),
    do: is_float(bottom) and bottom == 0.0 and absent_entity?(c) and movement?(c.piston_movement)

  def valid?(
        %__MODULE__{
          kind: :entity,
          bottom: bottom,
          descending: descending,
          placement: placement
        } = c
      ),
      do:
        is_number(bottom) and abs(bottom) <= 60_000_000 and is_boolean(descending) and
          is_boolean(placement) and valid_entity?(c) and movement?(c.piston_movement)

  def valid?(_), do: false
  defp movement?(dir), do: dir in [nil, :down, :up, :north, :south, :west, :east]

  defp absent_entity?(c),
    do:
      c.entity_present == false and is_float(c.fall_distance) and c.fall_distance == 0.0 and
        c.falling_block == false and c.powder_snow_walkable == false

  defp valid_entity?(%__MODULE__{entity_present: false} = c), do: absent_entity?(c)

  defp valid_entity?(%__MODULE__{entity_present: true} = c),
    do:
      is_number(c.fall_distance) and abs(c.fall_distance) <= 60_000_000 and
        is_boolean(c.falling_block) and is_boolean(c.powder_snow_walkable)

  defp valid_entity?(_), do: false

  # Native empty context answers the supplied fallback; entity context ignores it.
  def above?(%__MODULE__{kind: :empty}, _shape_top, _block_y, fallback), do: fallback

  def above?(%__MODULE__{kind: :entity, bottom: bottom}, shape_top, block_y, _fallback),
    do: bottom > block_y + shape_top - @epsilon
end
