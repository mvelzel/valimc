defmodule Valimc.CommandSnbtTest do
  use ExUnit.Case, async: true
  # SNBT values and item predicates; the commands oracle stage compares parse errors.
  alias Valimc.Command.{ItemPredicate, Reader, Snbt}
  alias Valimc.Protocol.ItemStack

  defp snbt(text), do: text |> Reader.new() |> Snbt.parse() |> elem(0)

  test "numbers keep vanilla's types, bases and suffixes" do
    assert snbt("1") == {:int, 1}
    assert snbt("1b") == {:byte, 1}
    assert snbt("-5s") == {:short, -5}
    assert snbt("0xFF") == {:int, 255}
    assert snbt("0xFFFFFFFF") == {:int, -1}
    assert snbt("255ub") == {:byte, -1}
    assert snbt("0b101L") == {:long, 5}
    assert snbt("1_000") == {:int, 1000}
    assert snbt("1.5f") == {:float, <<1.5::float-32>>}
    assert snbt(".5") == {:double, <<0.5::float-64>>}
    assert snbt("1e3") == {:double, <<1000.0::float-64>>}
  end

  test "strings, lists, arrays, compounds and built-ins" do
    assert snbt(~S("a\nb")) == {:string, "a\nb"}
    assert snbt(~S('é')) == {:string, "é"}
    assert snbt("abc") == {:string, "abc"}
    assert snbt("true") == {:byte, 1}
    assert snbt("[1,2]") == {:list, {:int, [1, 2]}}
    assert snbt("[I;1,2]") == {:int_array, <<1::32, 2::32>>}
    assert snbt("{a:1,a:2}") == {:compound, %{"a" => {:int, 2}}}
    assert snbt("bool(256)") == {:byte, 0}
    assert {:int_array, <<_::128>>} = snbt(~S|uuid("dd12be42-52a9-4a91-a8a1-11c01849e498")|)
  end

  test "item predicates match items, tags, counts and components" do
    predicate = fn text -> text |> Reader.new() |> ItemPredicate.parse() |> elem(0) end
    sword = %{ItemStack.new("diamond_sword", 1) | components: %{"minecraft:damage" => 5}}
    assert ItemPredicate.matches?(predicate.("diamond_sword[damage=5]"), sword)
    refute ItemPredicate.matches?(predicate.("diamond_sword[damage=4]"), sword)
    assert ItemPredicate.matches?(predicate.("*[damage]"), sword)
    refute ItemPredicate.matches?(predicate.("*[!damage]"), sword)
    assert ItemPredicate.matches?(predicate.("*[count={min:1,max:2}]"), sword)
    assert ItemPredicate.matches?(predicate.("#minecraft:swords"), sword)
    assert ItemPredicate.matches?(predicate.("diamond_sword[damage=9|count=1]"), sword)
    refute ItemPredicate.matches?(predicate.("stone[damage=5|count=1]"), sword)
  end
end
