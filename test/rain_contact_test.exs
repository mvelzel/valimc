defmodule Valimc.Physics.RainContactTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.RainContact

  test "snow and dry biomes cannot extinguish through rain, and duplicate points must agree" do
    assert {:ok, false} = RainContact.exposed?(true, 64, {64, true, :none}, {65, true, :none})
    assert {:ok, false} = RainContact.exposed?(true, 64, {64, true, :snow}, {65, true, :snow})

    assert {:error, :inconsistent_rain_observation} =
             RainContact.exposed?(true, 64, {64, true, :rain}, {64, false, :rain})

    assert {:error, :invalid_rain_observation} =
             RainContact.exposed?(true, 64, {64, true, :rain}, {67, true, :rain})

    assert {:error, :invalid_rain_observation} =
             RainContact.exposed?(nil, 64, {64, true, :rain}, {65, true, :rain})
  end
end
