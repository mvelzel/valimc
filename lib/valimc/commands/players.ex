defmodule Valimc.Commands.Players do
  @moduledoc "Player commands (VMC-053): game modes."
  alias Valimc.Command.{Feedback, GameRules, Source, Text}
  alias Valimc.Player.GameModes

  @doc "`/gamemode <gamemode> [<target>]` (`GameModeCommand`)."
  def gamemode(%{"gamemode" => mode} = arguments, source) do
    targets =
      case arguments do
        %{"target" => selector} -> Source.required_players(source, selector)
        _ -> [source.player]
      end

    name = Text.translatable("gameMode.#{mode}")

    Enum.reduce(targets, {0, source.state}, fn target, {count, state} ->
      cond do
        target.pid == self() ->
          case GameModes.set(state, mode) do
            {:changed, state} ->
              Feedback.success(
                %{source | state: state},
                Text.translatable("commands.gamemode.success.self", [name])
              )

              {count + 1, state}

            {:unchanged, state} ->
              {count, state}
          end

        target.game_mode.current != mode ->
          notice =
            if GameRules.get(:send_command_feedback),
              do: Text.translatable("gameMode.changed", [name])

          Valimc.Connection.deliver(
            target.pid,
            {:set_game_mode, mode, notice && Text.encode(notice)}
          )

          Feedback.success(
            %{source | state: state},
            Text.translatable("commands.gamemode.success.other", [
              Source.display_name(target),
              name
            ])
          )

          {count + 1, state}

        true ->
          {count, state}
      end
    end)
  end

  @doc "`/defaultgamemode <gamemode>`: new players' mode; no player is forced to it."
  def default_gamemode(%{"gamemode" => mode}, source) do
    Application.put_env(:valimc, :default_game_mode, mode)

    Feedback.success(
      source,
      Text.translatable("commands.defaultgamemode.success", [
        Text.translatable("gameMode.#{mode}")
      ])
    )

    {0, source.state}
  end
end
