defmodule Valimc.Physics.CookingItems do
  @moduledoc "Bounded immutable furnace slot proposals; callers must durably admit changes and remainder drops."
  alias Valimc.Physics.CookingFuel
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  @path Path.expand("../../../priv/physics/cooking_remainders.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @remainders Map.new(@facts["remainders"], fn {id, result} ->
                {String.to_integer(id), %ItemStack{item_id: result}}
              end)
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           Enum.all?(@remainders, fn {id, result} ->
             ItemTypes.item(id) != nil and ItemTypes.item(result.item_id) != nil
           end),
         do: raise("Wrong native cooking remainders")

  @doc "Complete one already selected recipe without mutating the supplied three-slot state."
  def finish(slots, result, limit \\ 64)

  def finish({%ItemStack{} = input, fuel, output}, %ItemStack{} = result, limit)
      when is_integer(limit) and limit in 1..99 do
    validate(input)
    validate(fuel)
    validate(output)
    validate(result)

    if accepts?(output, result, limit) do
      next_output = if output, do: %{output | count: output.count + result.count}, else: result

      next_fuel =
        if input.item_id == ItemTypes.id("wet_sponge") and fuel != nil and
             fuel.item_id == ItemTypes.id("bucket"),
           do: ItemStack.new("water_bucket"),
           else: fuel

      {:ok, {sized(input, input.count - 1), next_fuel, next_output}}
    else
      {:error, :output_full}
    end
  rescue
    _ -> {:error, :invalid_cooking_items}
  catch
    {:item_error, _} -> {:error, :invalid_cooking_items}
  end

  def finish(_, _, _), do: {:error, :invalid_cooking_items}

  @doc "Consume one admitted fuel; returned overflow still requires joint world-item admission."
  def consume_fuel(%ItemStack{} = fuel, state) do
    with {:ok, %{burn_ticks: ticks} = resolved} when ticks > 0 <- CookingFuel.resolve(fuel, state) do
      remaining = sized(fuel, fuel.count - 1)
      remainder = Map.get(@remainders, fuel.item_id)

      {next, drops} =
        cond do
          remainder == nil -> {remaining, []}
          remaining == nil -> {remainder, []}
          true -> {remaining, [remainder]}
        end

      {:ok, Map.merge(resolved, %{fuel: next, drops: drops})}
    else
      {:ok, _} -> {:error, :not_fuel}
      error -> error
    end
  end

  def consume_fuel(_, _), do: {:error, :invalid_cooking_items}

  defp accepts?(nil, _, _), do: true

  defp accepts?(output, result, limit),
    do:
      ItemStack.same_item?(output, result) and
        output.count + result.count <= min(limit, ItemStack.max_stack_size(result))

  defp sized(_, 0), do: nil
  defp sized(stack, count), do: %{stack | count: count}
  defp validate(nil), do: :ok
  defp validate(%ItemStack{} = stack), do: ItemStack.identity_key(stack)
end
