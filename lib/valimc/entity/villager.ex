defmodule Valimc.Entity.Villager do
  @moduledoc """
  A villager's own data (VMC-044a1): its `VillagerData` (type, profession,
  level) and whether it was finalized, its unhappy counter, its age
  (`AgeableMob`: negative while a baby), its trade experience and the bed it
  sleeps in. Generation gives a villager its template's NBT
  (`readAdditionalSaveData`): a `VillagerData` there, whole or in part,
  finalizes it, the rest defaulting to a plains villager without a
  profession.
  """
  alias Valimc.AI.Villagers

  @doc "A fresh villager's data (`defineSynchedData`)."
  def data,
    do: %{
      villager_type: "minecraft:plains",
      profession: "minecraft:none",
      level: 1,
      finalized: false,
      unhappy: 0,
      age: 0,
      xp: 0,
      sleeping: nil
    }

  @doc "Whether a villager of `data` is a baby."
  def baby?(%{age: age}), do: age < 0

  @doc "Its entity data values after the living ones: `[{field, value, default}]`."
  def values(%{} = data),
    do: [
      {:ageable_baby, baby?(data), false},
      {:villager_unhappy, data.unhappy, 0},
      {:villager_data,
       {Villagers.type_id(data.villager_type), Villagers.profession_id(data.profession),
        data.level}, {Villagers.type_id("minecraft:plains"), 0, 1}},
      {:villager_data_finalized, data.finalized, false}
    ]

  @doc """
  The data of a villager generation gave the SNBT `preserved`
  (`readAdditionalSaveData`): `VillagerData`, `VillagerDataFinalized`,
  `Age` and `Xp`.
  """
  def from_preserved(nil), do: data()

  def from_preserved(preserved) when is_binary(preserved) do
    {{:compound, tag}, _} = Valimc.Text.Snbt.parse_compound(Valimc.Text.Reader.new(preserved))
    base = data()

    base =
      case tag do
        %{"VillagerData" => {:compound, villager}} ->
          %{
            base
            | villager_type: string(villager["type"], &Villagers.type?/1, base.villager_type),
              profession:
                string(villager["profession"], &Villagers.profession?/1, base.profession),
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
    _ -> data()
  end

  defp string({:string, s}, valid, default), do: if(valid.(s), do: s, else: default)
  defp string(_, _valid, default), do: default

  defp int({kind, n}, _default) when kind in [:int, :byte, :short, :long], do: n
  defp int(_, default), do: default
end
