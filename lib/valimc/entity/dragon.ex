defmodule Valimc.Entity.Dragon do
  @moduledoc """
  What the owner reads of an ender dragon (VMC-045a4): its eight part boxes,
  which hits and the tracker address, from its row, whose data holds its
  actor (`mobs::boss::dragon`, VMC-081d); whether a podium phase ignites an
  arrow; and a generated dragon's data.
  """
  use Valimc.Data.Facts, "registry/dragon_facts.json"
  alias Valimc.Data.Float32

  @arrow_types ~w(minecraft:arrow minecraft:spectral_arrow minecraft:trident minecraft:wind_charge)
  @parts @facts["parts"] |> Enum.map(&{&1["width"], &1["height"]})
  @still List.duplicate({0.0, 0.0, 0.0}, length(@parts)) |> List.to_tuple()

  @doc "The network ids a dragon takes: its own and one per part."
  def id_span, do: 1 + length(@parts)

  @doc """
  A generated dragon's data over a fresh one's (`data`): the SNBT
  `preserved`'s phase, sitting damage and death time.
  """
  def from_preserved(nil, data), do: data

  def from_preserved(snbt, defaults) do
    {{:compound, fields}, _} = Valimc.Text.Snbt.parse_compound(Valimc.Text.Reader.new(snbt))
    phase = number(fields["DragonPhase"], 10)

    %{
      defaults
      | phase: if(phase in 0..10, do: phase, else: 0),
        sitting_damage: number(fields["sitting_damage_received"], 0.0) * 1.0,
        death_time: number(fields["DragonDeathTime"], 0)
    }
  rescue
    _ -> defaults
  end

  defp number({:float, <<n::float-32>>}, _default), do: n
  defp number({:double, <<n::float-64>>}, _default), do: n

  defp number({kind, n}, _default) when kind in [:byte, :short, :int, :long],
    do: n

  defp number(_, default), do: default

  @doc """
  The current eight part boxes, in the client's root+1 through root+8 order,
  of a dragon's row, whose data holds its actor and the actor its flight.
  """
  def boxes(%{data: %{brain: %{phases: %{flight: %{parts: parts}}}}}), do: boxes(parts)
  def boxes(%{data: %{brain: %{flight: %{parts: parts}}}}), do: boxes(parts)

  def boxes(parts) when is_tuple(parts) do
    for {{width, height}, {x, y, z}} <- Enum.zip(@parts, Tuple.to_list(parts)) do
      half = Float32.round(width / 2.0)
      {x - half, y, z - half, x + half, y + height, z + half}
    end
  end

  def boxes(_body), do: boxes(@still)

  @doc "The three podium phases reject and ignite arrows, tridents and player wind charges."
  def ignites?(%{data: %{phase: phase}}, hit),
    do: phase in [5, 6, 7] and match?(%{type: type} when type in @arrow_types, hit[:direct])
end
