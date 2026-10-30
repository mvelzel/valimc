defmodule Valimc.Data.AiFacts do
  @moduledoc """
  What the Elixir side reads of `ai_facts.json` (`MobAiOracle facts`):
  `Mth.atan2`'s tables and the swing packet's fields after the entity id.
  Native mobs read the whole file (`Valimc.Entity.MobFacts`).
  """
  use Valimc.Data.Facts, "registry/ai_facts.json"

  double = fn hex ->
    <<v::float-64>> = Base.decode16!(hex, case: :lower)
    v
  end

  @asin @facts["atan2"]["asin"] |> Enum.map(double) |> List.to_tuple()
  @cos @facts["atan2"]["cos"] |> Enum.map(double) |> List.to_tuple()
  @swing Base.decode16!(@facts["swing_fields"], case: :lower)

  @doc "`Mth.atan2`'s `ASIN_TAB` or `COS_TAB`."
  def atan2_table(:asin), do: @asin
  def atan2_table(:cos), do: @cos

  @doc """
  `ClientboundSwingAnimationPacket`'s fields after the entity id for a swing
  of `hand` (`:main_hand` or `:off_hand`, the hand's id first).
  """
  def swing_fields(:main_hand), do: @swing

  def swing_fields(:off_hand) do
    <<0, rest::binary>> = @swing
    <<1, rest::binary>>
  end
end
