defmodule Valimc.Physics.SneakEdges do
  @moduledoc "Bounded native player edge backoff; supplied support queries retain geometry errors."
  alias Valimc.Physics.Box

  defstruct flying: false,
            shift: false,
            on_ground: false,
            fall_distance: 0.0,
            max_step: 0.6000000238418579,
            mover: :player

  @max_queries 4096

  def step(box, {x, y, z} = requested, %__MODULE__{} = facts, free?) when is_function(free?, 1) do
    if valid?(box, requested, facts) do
      step = f32(facts.max_step)
      state = %{box: box, free?: free?, queries: 0}

      if not facts.flying and y <= 0 and facts.mover in [:self, :player] and facts.shift do
        with {:ok, above, state} <- above_ground(facts, step, state),
             {:ok, x, z, state} <-
               if(above, do: backoff(x, z, step, state), else: {:ok, x, z, state}),
             do: {:ok, %{requested: {x, y, z}, queries: state.queries}}
      else
        {:ok, %{requested: requested, queries: 0}}
      end
    else
      {:error, :invalid_sneak_edges}
    end
  end

  def step(_, _, _, _), do: {:error, :invalid_sneak_edges}

  defp above_ground(%{on_ground: true}, _, state), do: {:ok, true, state}

  defp above_ground(%{fall_distance: fall}, step, state) when fall >= step,
    do: {:ok, false, state}

  defp above_ground(%{fall_distance: fall}, step, state) do
    with {:ok, free, state} <- query(state, 0.0, 0.0, step - fall),
         do: {:ok, not free, state}
  end

  defp backoff(x, z, step, state) do
    with {:ok, x, _, state} <- reduce(x, 0.0, sign(x) * 0.05, 0.0, step, state),
         {:ok, _, z, state} <- reduce(0.0, z, 0.0, sign(z) * 0.05, step, state) do
      if x == 0 or z == 0,
        do: {:ok, x, z, state},
        else: reduce(x, z, sign(x) * 0.05, sign(z) * 0.05, step, state)
    end
  end

  defp reduce(x, z, sx, sz, _step, state)
       when (sx == 0 or x == 0) and (sz == 0 or z == 0), do: {:ok, x, z, state}

  # The diagonal phase stops when either component reaches zero; the separate
  # axis phases have already established the remaining component's support.
  defp reduce(x, z, sx, sz, _step, state) when sx != 0 and sz != 0 and (x == 0 or z == 0),
    do: {:ok, x, z, state}

  defp reduce(x, z, sx, sz, step, state) do
    with {:ok, free, state} <- query(state, x, z, step) do
      if free,
        do: reduce(shrink(x, sx), shrink(z, sz), sx, sz, step, state),
        else: {:ok, x, z, state}
    end
  end

  defp query(%{queries: count}, _, _, _) when count >= @max_queries,
    do: {:error, :sneak_query_limit}

  defp query(%{box: {a, b, c, d, _, f}} = state, x, z, drop) do
    box = {a + 1.0e-7 + x, b - drop - 1.0e-7, c + 1.0e-7 + z, d - 1.0e-7 + x, b, f - 1.0e-7 + z}

    if Box.valid?(box) do
      case state.free?.(box) do
        {:ok, free} when is_boolean(free) -> {:ok, free, %{state | queries: state.queries + 1}}
        {:error, _} = error -> error
        _ -> {:error, :invalid_sneak_observation}
      end
    else
      {:error, :sneak_query_limit}
    end
  end

  defp shrink(value, step), do: if(abs(value) <= 0.05, do: 0.0, else: value - step)
  defp sign(value) when value < 0, do: -1.0
  defp sign(value) when value > 0, do: 1.0
  defp sign(_), do: 0.0

  defp valid?(box, {x, y, z}, facts) do
    Box.valid?(box) and Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64)) and
      Enum.all?([facts.flying, facts.shift, facts.on_ground], &is_boolean/1) and
      is_number(facts.fall_distance) and facts.fall_distance >= 0 and
      facts.fall_distance <= 60_000_000 and
      is_number(facts.max_step) and facts.max_step >= 0 and facts.max_step <= 4 and
      facts.mover in [:self, :player, :piston, :shulker, :shulker_box]
  end

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
