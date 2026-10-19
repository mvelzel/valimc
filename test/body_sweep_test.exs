defmodule Valimc.Physics.BodySweepTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BodySweep, Box, PlayerPose}

  defp body(point) do
    {:ok, %{box: {a, b, c, d, e, f}}} = PlayerPose.geometry(:standing, point)
    epsilon = 9.999999747378752e-6
    Box.new({a + epsilon, b + epsilon, c + epsilon, d - epsilon, e - epsilon, f - epsilon})
  end

  test "oversized work and malformed geometry fail before an unbounded traversal" do
    p = {0.5, 64.0, 0.5}
    assert {:error, :body_sweep_limit} = BodySweep.plan(p, {65.5, 64.0, 0.5}, body(p))
    assert {:error, :body_sweep_limit} = BodySweep.plan(p, p, Box.new({0, 0, 0, 16, 16, 16}))
    assert {:error, :invalid_body_sweep} = BodySweep.plan(p, p, body(p), 513)
    assert {:error, :invalid_body_sweep} = BodySweep.plan(:bad, p, body(p))
    from = {0.0, 64.0, 0.0}
    to = {1.0, 64.0, -1.0e-320}
    assert {:error, :body_sweep_limit} = BodySweep.plan(from, to, body(to))
    edge = {-60_000_000.0, 64.0, 0.0, -59_999_999.0, 65.0, 1.0}
    assert {:error, :body_sweep_limit} = BodySweep.plan(from, {1.0, 64.0, 0.0}, edge)
  end
end
