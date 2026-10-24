defmodule Valimc.Commands.SparkStyle do
  @moduledoc false
  alias Valimc.Text
  def text(line, color \\ "gray"), do: line |> Text.literal() |> Text.color(color)
  def prefix(component) when is_binary(component), do: prefix(text(component))

  def prefix(component) do
    text("")
    |> Text.append(text("[", "dark_gray"))
    |> Text.append(text("⚡", "yellow") |> Text.style([{"bold", true}]))
    |> Text.append(text("]", "dark_gray"))
    |> Text.append(text(" "))
    |> Text.append(component)
  end

  def prompt(command) do
    text("  ")
    |> Text.append(
      text(command, "white")
      |> Text.style([
        {"click_event",
         {:compound,
          %{
            "action" => {:string, "run_command"},
            "command" => {:string, command}
          }}}
      ])
    )
  end

  def url(url) do
    text(url)
    |> Text.style([
      {"click_event", {:compound, %{"action" => {:string, "open_url"}, "url" => {:string, url}}}}
    ])
  end

  def tps(n, target) do
    color =
      cond do
        n > target * 0.9 -> "green"
        n > target * 0.8 -> "yellow"
        true -> "red"
      end

    value = min(Float.round(n / 1, 2), target / 1)
    text(if(n > target, do: "*", else: "") <> to_string(value), color)
  end

  def duration(n, target \\ 50) do
    color =
      cond do
        n >= target -> "red"
        n >= target * 0.8 -> "yellow"
        true -> "green"
      end

    text(:erlang.float_to_binary(n / 1, decimals: 1), color)
  end

  def utilization(n) do
    color =
      cond do
        n > 90 -> "red"
        n > 65 -> "yellow"
        true -> "green"
      end

    text(:erlang.float_to_binary(n / 1, decimals: 0) <> "%", color)
  end

  def ping(n),
    do:
      text(
        to_string(ceil(n)),
        cond do
          n >= 200 -> "red"
          n >= 100 -> "yellow"
          true -> "green"
        end
      )

  def values(values, separator \\ ", "),
    do: text(" ") |> Text.append(Text.join(values, text(separator)))
end
