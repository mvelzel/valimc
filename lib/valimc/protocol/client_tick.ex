defmodule Valimc.Protocol.ClientTick do
  @moduledoc "Per-connection client-frame admission, independent of server simulation ticks."
  defstruct position_received?: false

  def position(%__MODULE__{position_received?: false} = frame),
    do: {:ok, %{frame | position_received?: true}}

  def position(%__MODULE__{}), do: {:error, :duplicate_position}
  def finish(%__MODULE__{}), do: %__MODULE__{}
end
