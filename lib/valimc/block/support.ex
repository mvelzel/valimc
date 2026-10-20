defmodule Valimc.Block.Support do
  @moduledoc """
  Vanilla survival on neighbour updates (VMC-029c), from `SupportOracle` facts.

  A dependent state has a profile: an optional survival rule (vanilla `canSurvive`),
  a reaction per update direction while it cannot survive (break at once, schedule
  its tick, or nothing; vanilla `updateShape`) and neighbour overrides: states in a
  direction that break it although it can survive (the missing other half of a
  door, bed or tall plant) or keep it although it cannot.

  A rule reads the states at a few offsets. Each offset has a partition of all
  states into classes that `canSurvive` treats alike, and a table over the class
  combinations says whether the state survives. Directions are vanilla `Direction`
  order (down, up, north, south, west, east) and point from the dependent block to
  the changed neighbour. A neighbour the caller cannot read (`nil`, another
  region) never breaks anything.
  """
  import Bitwise, only: [<<<: 2, |||: 2]
  alias Valimc.Registry.Blocks

  @path Path.expand("../../../priv/physics/support.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count Blocks.state_count()
  unless Valimc.Version.stamped?(@facts) and @facts["state_count"] == @count,
    do: raise("Wrong support facts version")

  @directions {{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}}

  # Each partition packs one class per state at the fewest bits that hold its classes.
  @partitions Enum.map(@facts["partitions"], fn runs ->
                pairs = Enum.chunk_every(runs, 2)
                classes = pairs |> Enum.map(&List.last/1) |> Enum.max()
                bits = max(1, ceil(:math.log2(classes + 1)))

                unless hd(runs) == 0 and classes < 256 and
                         Enum.all?(Enum.chunk_every(pairs, 2, 1, :discard), fn [[a, _], [b, _]] ->
                           a < b and b < @count
                         end),
                       do: raise("Invalid support partition")

                packed =
                  for {[first, class], next} <-
                        Enum.zip(pairs, tl(Enum.map(pairs, &hd/1)) ++ [@count]),
                      _ <- first..(next - 1)//1,
                      into: <<>>,
                      do: <<class::size(bits)>>

                {bits, packed, classes + 1}
              end)
              |> List.to_tuple()

  @rules Enum.map(@facts["rules"], fn %{
                                        "offsets" => offsets,
                                        "partitions" => partitions,
                                        "table" => table
                                      } ->
           radices = Enum.map(partitions, &elem(elem(@partitions, &1), 2))

           unless length(offsets) == length(partitions) and
                    byte_size(table) == Enum.product(radices) and
                    String.match?(table, ~r/\A[01]+\z/),
                  do: raise("Invalid support rule")

           {Enum.zip(Enum.map(offsets, &List.to_tuple/1), partitions),
            for(<<bit <- table>>, into: <<>>, do: <<bit - ?0::1>>)}
         end)
         |> List.to_tuple()

  # The oracle omits a missing rule.
  @profiles Enum.map(@facts["profiles"], fn %{"reactions" => reactions, "overrides" => overrides} =
                                              profile ->
              rule = profile["rule"]

              unless (rule == nil or rule in 0..(tuple_size(@rules) - 1)) and
                       length(reactions) == 6 and Enum.all?(reactions, &(&1 >= -1)) and
                       (rule != nil or Enum.all?(reactions, &(&1 == 0))),
                     do: raise("Invalid support profile")

              overrides =
                Map.new(overrides, fn [direction, partition, codes] ->
                  unless direction in 0..5 and Enum.all?(codes, &(&1 in 0..2)) and
                           length(codes) == elem(elem(@partitions, partition), 2),
                         do: raise("Invalid support override")

                  {direction,
                   {partition, List.to_tuple(Enum.map(codes, &elem({:rule, :break, :keep}, &1)))}}
                end)

              {rule, List.to_tuple(reactions), overrides}
            end)
            |> List.to_tuple()

  @runs Enum.sort(@facts["states"])
  @by_state for(
              {[first, last, profile], previous} <-
                Enum.zip(@runs, [-1 | Enum.map(@runs, &Enum.at(&1, 1))]),
              into: <<>>,
              do:
                :binary.copy(<<0::16>>, first - previous - 1) <>
                  :binary.copy(<<profile + 1::16>>, last - first + 1)
            ) <> :binary.copy(<<0::16>>, @count - 1 - Enum.at(List.last(@runs), 1))

  unless byte_size(@by_state) == 2 * @count and
           Enum.sum(for [first, last, _] <- @facts["states"], do: last - first + 1) ==
             @facts["dependent_states"],
         do: raise("Invalid support state runs")

  # Breaking turns a block into air; air itself never depends on anything.
  for name <- ~w(air cave_air void_air),
      :binary.at(@by_state, 2 * Blocks.default_state(name) + 1) != 0 or
        :binary.at(@by_state, 2 * Blocks.default_state(name)) != 0,
      do: raise("Air must not have support facts")

  @doc "Whether the state has survival facts."
  def dependent?(state), do: profile(state) != nil

  @doc "Unit vector of a direction (0..5)."
  def direction(d), do: elem(@directions, d)

  @doc """
  Vanilla `updateShape` after the neighbours in `directions` changed: `:keep`,
  `:break` (vanilla returns air) or `{:tick, delay}` (vanilla schedules the
  block's tick, which breaks it if it still cannot survive).
  """
  def update(position, state, directions, read) do
    case profile(state) do
      nil ->
        :keep

      {rule, reactions, overrides} ->
        decided = Enum.group_by(directions, &override(overrides, position, &1, read))

        triggered =
          for d <- Map.get(decided, :rule, []), (reaction = elem(reactions, d)) != 0, do: reaction

        cond do
          Map.has_key?(decided, :break) -> :break
          triggered == [] or rule_survives?(rule, position, read) -> :keep
          -1 in triggered -> :break
          true -> {:tick, Enum.min(triggered)}
        end
    end
  end

  @doc "At the block's tick: whether it can no longer survive or a neighbour override breaks it."
  def breaks?(position, state, read) do
    case profile(state) do
      nil ->
        false

      {rule, _, overrides} ->
        not rule_survives?(rule, position, read) or
          Enum.any?(Map.keys(overrides), &(override(overrides, position, &1, read) == :break))
    end
  end

  @doc "Vanilla `canSurvive` from the neighbours `read` returns (true when one is unknown)."
  def survives?(position, state, read) do
    case profile(state) do
      nil -> true
      {rule, _, _} -> rule_survives?(rule, position, read)
    end
  end

  defp rule_survives?(nil, _position, _read), do: true

  defp rule_survives?(rule, {x, y, z}, read) do
    {offsets, table} = elem(@rules, rule)

    index =
      Enum.reduce_while(offsets, 0, fn {{dx, dy, dz}, partition}, index ->
        case read.({x + dx, y + dy, z + dz}) do
          nil ->
            {:halt, nil}

          neighbour ->
            {_, _, radix} = elem(@partitions, partition)
            {:cont, index * radix + class(partition, neighbour)}
        end
      end)

    index == nil or match?(<<_::bitstring-size(^index), 1::1, _::bitstring>>, table)
  end

  # What the neighbour in direction `d` decides: `:break`, `:keep` or `:rule`.
  defp override(overrides, {x, y, z}, d, read) do
    case overrides do
      %{^d => {partition, codes}} ->
        {dx, dy, dz} = elem(@directions, d)

        case read.({x + dx, y + dy, z + dz}) do
          nil -> :keep
          neighbour -> elem(codes, class(partition, neighbour))
        end

      _ ->
        :rule
    end
  end

  defp class(partition, state) do
    {bits, packed, _} = elem(@partitions, partition)
    skip = state * bits
    <<_::bitstring-size(^skip), class::size(^bits), _::bitstring>> = packed
    class
  end

  defp profile(state) when is_integer(state) and state >= 0 and state < @count do
    case :binary.at(@by_state, 2 * state) <<< 8 ||| :binary.at(@by_state, 2 * state + 1) do
      0 -> nil
      index -> elem(@profiles, index - 1)
    end
  end

  defp profile(_), do: nil
end
