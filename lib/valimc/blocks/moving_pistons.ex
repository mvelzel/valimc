defmodule Valimc.Blocks.MovingPistons do
  @moduledoc """
  A moving piston's block entity (VMC-048b, `PistonMovingBlockEntity`) as
  the owner, the rules and the kernel exchange it (`valimc_core::piston::Moving`
  records) and as clients read it (`getUpdateTag`): a chunk packet lists
  each one with the block it carries, its facing, progress and whether it
  extends and is the piston's own, so a client loading the chunk mid-move
  draws it.
  """
  import Bitwise
  alias Valimc.Data.{Blocks, NBT}

  @type_id Valimc.Blocks.BlockEntityTypes.type_named("minecraft:piston")

  @doc """
  A moving piston's block entity (`valimc_core::piston::Moving`, VMC-048b)
  from its packed record: `{position, {moved, direction, extending?,
  source?, progress, progress_o, last_ticked, order}}`.
  """
  def unpack(
        <<x::32-signed, y::32-signed, z::32-signed, moved::16, direction, flags,
          progress::float-32, progress_o::float-32, last::64-signed, order::64-signed>>
      ),
      do:
        {{x, y, z},
         {moved, direction, (flags &&& 1) == 1, (flags &&& 2) == 2, progress, progress_o, last,
          order}}

  @doc "The packed record of a moving piston's block entity (`unpack/1`'s inverse)."
  def pack({{x, y, z}, {moved, direction, extending, source, progress, old, last, order}}) do
    flags = if(extending, do: 1, else: 0) ||| if(source, do: 2, else: 0)

    <<x::32-signed, y::32-signed, z::32-signed, moved::16, direction, flags, progress::float-32,
      old::float-32, last::64-signed, order::64-signed>>
  end

  @doc "The network id of the piston block entity type."
  def type_id, do: @type_id

  @doc """
  The update tag (network NBT) of `{moved, direction, extending?, source?,
  progress, progress_o, last_ticked, order}`; vanilla saves the old progress.
  """
  def update_tag({moved, direction, extending, source, _progress, progress_o, _, _}) do
    properties =
      for {name, value} <- Blocks.properties(moved), into: %{}, do: {name, {:string, value}}

    state =
      %{"Name" => {:string, "minecraft:" <> Blocks.name(Blocks.block_id(moved))}}
      |> then(
        &if properties == %{}, do: &1, else: Map.put(&1, "Properties", {:compound, properties})
      )

    tag =
      {:compound,
       %{
         "blockState" => {:compound, state},
         "facing" => {:int, direction},
         "progress" => {:float, progress_o},
         "extending" => {:byte, if(extending, do: 1, else: 0)},
         "source" => {:byte, if(source, do: 1, else: 0)}
       }}

    IO.iodata_to_binary(NBT.encode(tag))
  end
end
