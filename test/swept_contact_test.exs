defmodule Valimc.Physics.SweptContactTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.Box

  test "face touching is excluded but actual overlap is retained" do
    shape = Box.new({0.0, 64.0, 0.0, 1.0, 65.0, 1.0})
    body = Box.new({0.2, 65.0, 0.2, 0.8, 66.8, 0.8})
    refute Box.collided_along?(body, {0.0, 0.0, 0.0}, [shape])
    assert Box.collided_along?(Box.move(body, {0.0, -0.001, 0.0}), {0.0, 0.0, 0.0}, [shape])
    assert Box.clip(shape, {-1.0, 64.5, 0.5}, {2.0, 64.5, 0.5}) == {0.0, 64.5, 0.5}
    assert Box.clip(shape, {0.5, 64.5, 0.5}, {2.0, 64.5, 0.5}) == nil
  end
end
