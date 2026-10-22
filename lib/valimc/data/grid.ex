defmodule Valimc.Data.Grid do
  @moduledoc """
  The world's grid (VMC-077r): chunks of 16 × 16 columns, sections of
  `region_size/0` × `region_size/0` chunks that one group process owns
  (VMC-077j), and the build height every level fits in. Pure coordinate
  arithmetic shared by every layer; `Valimc.World` routes on it.

  A section's routing key is dimension-explicit, `{dimension, sx, sz}`: equal
  coordinates of two dimensions never meet, and a plain `{sx, sz}` is refused
  rather than taken for the overworld (finding C8).
  """
  @levels [:overworld, :the_nether, :the_end]
  @region_size 8
  @min_y -64
  @max_y 319

  @doc "The normal world preset's levels, in the order of their stored codes."
  def levels, do: @levels

  @doc "Chunks per section side."
  def region_size, do: @region_size

  @doc "The lowest and highest block of any level."
  def min_y, do: @min_y
  def max_y, do: @max_y

  @doc "The chunk `{cx, cz}` holding the block column at `x`, `z`."
  def chunk_key(x, z), do: {Integer.floor_div(floor(x), 16), Integer.floor_div(floor(z), 16)}

  @doc "The section coordinates `{sx, sz}` of a chunk (geometry, no dimension)."
  def region_key({cx, cz}),
    do: {Integer.floor_div(cx, @region_size), Integer.floor_div(cz, @region_size)}

  @doc """
  The routing key of the section of `dimension` that holds chunk `chunk`, or
  whose coordinates are `{sx, sz}` (`at: :section`).
  """
  def section(dimension, chunk, at \\ :chunk)
  def section(dimension, chunk, :chunk), do: section(dimension, region_key(chunk), :section)

  def section(dimension, {sx, sz}, :section) when is_atom(dimension),
    do: {dimension, sx, sz}

  @doc "Whether `key` is a section's routing key."
  def section?({dimension, sx, sz}),
    do: dimension in @levels and is_integer(sx) and is_integer(sz)

  def section?(_), do: false

  @doc "A section key's dimension and coordinates: `{dimension, {sx, sz}}`."
  def split_section({dimension, sx, sz}), do: {dimension, {sx, sz}}
end
