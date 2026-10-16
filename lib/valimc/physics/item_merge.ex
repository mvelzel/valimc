defmodule Valimc.Physics.ItemMerge do
  @moduledoc "Pure item-pair decisions; ownership, proximity and durable publication belong to the caller."
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack

  def eligible?(%{stack: %ItemStack{} = stack, motion: %ItemMotionState{} = motion, alive: true}) do
    _ = ItemStack.identity_key(stack)

    ItemMotionState.valid?(motion) and
      motion.pickup_delay != 32_767 and motion.age != -32_768 and motion.age < 6000 and
      stack.count < ItemStack.max_stack_size(stack)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def eligible?(_), do: false

  def pair(%{target: target} = a, %{target: target} = b) do
    with true <- eligible?(a) and eligible?(b),
         true <- a.stack.count + b.stack.count <= ItemStack.max_stack_size(b.stack),
         true <- ItemStack.same_item?(a.stack, b.stack) do
      {side, recipient, donor} =
        if b.stack.count < a.stack.count, do: {:a, a, b}, else: {:b, b, a}

      amount =
        min(
          min(ItemStack.max_stack_size(recipient.stack), 64) - recipient.stack.count,
          donor.stack.count
        )

      {:ok,
       %{
         recipient: side,
         stack: %{recipient.stack | count: recipient.stack.count + amount},
         donor_stack:
           if(donor.stack.count == amount,
             do: nil,
             else: %{donor.stack | count: donor.stack.count - amount}
           ),
         motion: %{
           recipient.motion
           | age: min(recipient.motion.age, donor.motion.age),
             pickup_delay: max(recipient.motion.pickup_delay, donor.motion.pickup_delay)
         }
       }}
    else
      _ -> {:error, :not_mergeable}
    end
  rescue
    _ -> {:error, :not_mergeable}
  catch
    _, _ -> {:error, :not_mergeable}
  end

  def pair(_, _), do: {:error, :not_mergeable}

  @doc "Native item boxes are a quarter block wide/high; the query expands only X and Z."
  def near?({ax, ay, az}, {bx, by, bz}) do
    bx + 0.125 > ax - 0.125 - 0.5 and bx - 0.125 < ax + 0.125 + 0.5 and
      by + 0.25 > ay and by < ay + 0.25 and
      bz + 0.125 > az - 0.125 - 0.5 and bz - 0.125 < az + 0.125 + 0.5
  end
end
