defmodule Check.KernelShapes do
  @moduledoc """
  Shared helpers for the collision shape checks (VMC-077l): the shape the
  physics kernel picks for a state, compared with vanilla's geometry, and
  clips through the kernel. Load with `Code.require_file("kernel_shapes.exs",
  __DIR__)`.
  """
  alias Valimc.Native
  alias Valimc.Physics.{CollisionContext, Kernel}

  @axes %{"x" => 0, "y" => 1, "z" => 2}

  @doc "A collision context from an oracle's `context` facts."
  def context(%{"kind" => "empty"}), do: CollisionContext.empty()

  def context(f) do
    ctx = CollisionContext.entity(f["bottom"], f["descending"], f["placement"])

    if f["entity_present"],
      do:
        CollisionContext.with_entity(ctx, f["fall_distance"], f["falling_block"], f["walkable"]),
      else: ctx
  end

  @doc "The kernel's `{local shape, block offset}` for a state at a position."
  def picked(state, {x, y, z}, context),
    do: Native.physics_parity_shape(state, {x, y, z}, Kernel.context(context))

  @doc "Whether a picked shape, moved by its offset, is vanilla's `geometry`."
  def same?({{axes, sizes, bits}, offset}, geometry) do
    {expected_axes, expected_sizes, expected_bits} = Kernel.shape(geometry)

    moved =
      case offset do
        nil -> axes
        {ox, oy, oz} -> Enum.zip_with(axes, [ox, oy, oz], fn a, o -> Enum.map(a, &(&1 + o)) end)
      end

    bits_of = fn list -> Enum.map(list, fn a -> Enum.map(a, &<<&1::float-64>>) end) end

    bits_of.(moved) == bits_of.(expected_axes) and sizes == expected_sizes and
      bits == expected_bits
  end

  @doc "A picked shape placed at a block position, as a kernel collider."
  def collider({shape, offset}, {x, y, z}), do: {shape, offset, {x * 1.0, y * 1.0, z * 1.0}}

  @doc "Whether every query's clip through the kernel is vanilla's, bit for bit."
  def clips?(colliders, queries) do
    Enum.all?(queries, fn q ->
      box = q["box"] |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()

      value =
        Native.physics_parity_clip(
          colliders,
          Map.fetch!(@axes, q["axis"]),
          box,
          q["delta"] * 1.0,
          false
        )

      Base.encode16(<<value::float-64>>, case: :lower) == q["result_bits"]
    end)
  end
end
