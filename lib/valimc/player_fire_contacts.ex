defmodule Valimc.PlayerFireContacts do
  @moduledoc "Bounded ordered fire/fluid operations from a worker's contact steps; owners apply them while alive."
  @limit 2048
  @kinds [:fire, :soul_fire, :lava, :water, :powder_snow]

  def plan(steps) when is_list(steps) and length(steps) <= @limit do
    with {:ok, _count} <-
           Enum.reduce_while(steps, {:ok, 0}, fn contacts, {:ok, count} ->
             if is_list(contacts) and length(contacts) + count <= @limit and
                  Enum.all?(contacts, &(&1 in @kinds)),
                do: {:cont, {:ok, count + length(contacts)}},
                else: {:halt, {:error, :invalid_fire_contacts}}
           end) do
      {:ok, Enum.flat_map(steps, &step/1)}
    end
  end

  def plan(_), do: {:error, :invalid_fire_contacts}

  defp step(contacts) do
    fire = Enum.filter(contacts, &(&1 in [:fire, :soul_fire]))
    lava = Enum.count(contacts, &(&1 == :lava))

    # Ignitions deduplicate within a movement step; each contacted block retains
    # its damage callback. Extinguishing follows both kinds of ignition.
    if(fire != [] or lava > 0, do: [:clear_freeze], else: []) ++
      if(fire != [],
        do: [
          :fire_ignite | Enum.map(fire, &{:damage, :in_fire, if(&1 == :fire, do: 1.0, else: 2.0)})
        ],
        else: []
      ) ++
      if(lava > 0, do: [:lava_ignite | List.duplicate(:lava_hurt, lava)], else: []) ++
      if(:water in contacts or :powder_snow in contacts, do: [:extinguish], else: [])
  end
end
