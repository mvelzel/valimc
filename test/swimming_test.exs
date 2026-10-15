defmodule Valimc.Physics.SwimmingTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.Swimming

  test "swimming starts with submerged eyes and water at the feet, then persists at the surface" do
    assert Swimming.next(false, true, true, true, true, false)
    refute Swimming.next(false, true, true, false, true, false)
    refute Swimming.next(false, true, true, true, false, false)
    assert Swimming.next(true, true, true, false, false, false)
    refute Swimming.next(true, true, false, true, true, false)
  end

  test "stopping sprint or becoming a passenger clears swimming even under water" do
    refute Swimming.next(true, false, true, true, true, false)
    refute Swimming.next(true, true, true, true, true, true)
  end
end
