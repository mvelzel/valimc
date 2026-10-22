defmodule Valimc.Commands.PostEffects do
  @moduledoc """
  `/posteffect` (VMC-053i): changes each target's post-effect list in its own
  connection (`Valimc.Player.PostEffects`).
  """
  alias Valimc.Text.Error
  alias Valimc.Commands.{Feedback, Source, Targets}
  alias Valimc.Text
  alias Valimc.Commands.Remote

  @doc "`/posteffect add|remove <targets> <posteffect>`, `clear <targets>`, `list <target>`."
  def posteffect(%{literals: [mode]} = arguments, source) do
    case {mode, arguments} do
      {"add", %{"targets" => selector, "posteffect" => id}} ->
        change(source, selector, {:add, id}, "add", id)

      {"remove", %{"targets" => selector, "posteffect" => id}} ->
        change(source, selector, {:remove, id}, "remove", id)

      {"clear", %{"targets" => selector}} ->
        change(source, selector, :clear, "clear", nil)

      {"list", %{"target" => selector}} ->
        list(selector, source)
    end
  end

  defp change(source, selector, operation, key, id) do
    targets = Targets.required_players(source, selector)

    changed =
      for {target, true} <- Remote.run_all!(targets, fn _ -> {:post_effect, operation} end),
          do: target

    args = if id, do: [id], else: []

    if changed == [], do: Error.fail!("commands.posteffect.#{key}.failed")
    Feedback.targets(source, changed, "commands.posteffect.#{key}.success", args)
    length(changed)
  end

  defp list(selector, source) do
    target = Targets.single_player(source, selector)
    ids = Map.get(target, :post_effects, [])
    name = Source.display_name(target)

    message =
      if ids == [],
        do: Text.translatable("commands.posteffect.list.empty", [name]),
        else:
          Text.translatable("commands.posteffect.list.success", [
            name,
            length(ids),
            Enum.join(ids, ", ")
          ])

    Feedback.success(source, message, false)
    length(ids)
  end
end
