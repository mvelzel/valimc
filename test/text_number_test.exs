defmodule Valimc.TextNumberTest do
  @moduledoc "Java's number formatting in messages (VMC-077o; commands audit E13)."
  use ExUnit.Case, async: true
  alias Valimc.Text.Number

  test "%.Nf rounds the shortest digits half up, as Java does" do
    # Erlang's exact binary rounding printed 1.000000 here.
    assert Number.fixed(1.0000005, 6) == "1.000001"
    assert Number.fixed(0.125, 2) == "0.13"
    assert Number.fixed(-2.5, 0) == "-3"
    assert Number.fixed(20.0, 1) == "20.0"
  end

  test "Float.toString and Double.toString" do
    assert Number.java(1.0e7, 64) == "1.0E7"
    <<tenth::float-32>> = <<0.1::float-32>>
    assert Number.java(tenth, 32) == "0.1"
    assert Number.java(123.0, 64) == "123.0"
    assert Number.java(1.0e-4, 64) == "1.0E-4"
    assert Valimc.Text.Snbt.to_string({:float, <<1.0e7::float-32>>}) == "1.0E7f"
  end
end
