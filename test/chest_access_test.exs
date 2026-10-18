defmodule Valimc.ChestAccessTest do
  use ExUnit.Case, async: true
  alias Valimc.ChestAccess
  @facts JSON.decode!(File.read!("priv/protocol/chest_states.json"))
  @block hd(@facts["single_states"])

  test "actions require fresh living non-spectator access and a single ordinary chest" do
    position = {0, 64, 0}
    actor = %{mode: :survival, eye: {0.5, 65.6, 0.5}, health: 20.0, expires: 250}

    for mode <- [:survival, :creative, :adventure],
        do: assert(:ok == ChestAccess.authorize(@block, position, %{actor | mode: mode}, 0))

    for changed <- [
          %{actor | mode: :spectator},
          %{actor | health: 0},
          %{actor | eye: {99, 65, 0}}
        ],
        do:
          assert(
            {:error, :invalid_container_context} ==
              ChestAccess.authorize(@block, position, changed, 0)
          )

    assert {:error, :expired_container_context} =
             ChestAccess.authorize(@block, position, actor, 250)

    assert {:error, :expired_container_context} =
             ChestAccess.authorize(@block, position, %{actor | expires: 251}, 0)

    for state <- @facts["states"],
        state["part"] != "single",
        do: refute(ChestAccess.valid_view?(state["state"], :survival, actor.eye, position))

    refute ChestAccess.single?(0)
    refute ChestAccess.valid_view?(@block, :unknown, actor.eye, position)
    assert {:error, :invalid_container_context} = ChestAccess.authorize(@block, position, %{}, 0)
  end
end
