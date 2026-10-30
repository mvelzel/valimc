defmodule Valimc.Entity.Villager do
  @moduledoc """
  A generated villager's data (VMC-044a1): generation gives a villager its
  template's NBT (`readAdditionalSaveData`), whose `VillagerData` (type,
  profession, level), whole or in part, finalizes it over a fresh
  villager's data (a plains villager without a profession), with its `Age`
  and trade experience.
  """
  alias Valimc.Data.VillageFacts

  @doc """
  The data of a villager generation gave the SNBT `preserved`
  (`readAdditionalSaveData`): `VillagerData`, `VillagerDataFinalized`,
  `Age` and `Xp`.
  """
  def from_preserved(nil, data), do: data

  def from_preserved(preserved, data) when is_binary(preserved) do
    {{:compound, tag}, _} = Valimc.Text.Snbt.parse_compound(Valimc.Text.Reader.new(preserved))
    base = data

    base =
      case tag do
        %{"VillagerData" => {:compound, villager}} ->
          %{
            base
            | villager_type: string(villager["type"], &VillageFacts.type?/1, base.villager_type),
              profession:
                string(villager["profession"], &VillageFacts.profession?/1, base.profession),
              level: int(villager["level"], base.level),
              finalized: true
          }

        _ ->
          base
      end

    base =
      case tag do
        %{"VillagerDataFinalized" => {:byte, 1}} -> %{base | finalized: true}
        _ -> base
      end

    %{base | age: int(tag["Age"], 0), xp: int(tag["Xp"], 0)}
  rescue
    _ -> data
  end

  defp string({:string, s}, valid, default), do: if(valid.(s), do: s, else: default)
  defp string(_, _valid, default), do: default

  defp int({kind, n}, _default) when kind in [:int, :byte, :short, :long], do: n
  defp int(_, default), do: default
end
