defmodule Valimc.Commands.Names do
  @moduledoc "Display names that vanilla command feedback embeds (VMC-053): effects, modes."
  alias Valimc.Text

  def effect("minecraft:" <> name), do: Text.translatable("effect.minecraft.#{name}")
  def game_mode(mode), do: Text.translatable("gameMode.#{mode}")

  def difficulty(level),
    do:
      Text.translatable(
        "options.difficulty.#{elem({"peaceful", "easy", "normal", "hard"}, level)}"
      )
end
