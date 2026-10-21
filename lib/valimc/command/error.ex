defmodule Valimc.Command.Error do
  @moduledoc """
  Brigadier's `CommandSyntaxException` (VMC-053): a message component plus,
  for parse errors, the input and cursor that vanilla shows as `...text<--[HERE]`.
  """
  alias Valimc.Command.Reader
  alias Valimc.Text

  defstruct [:message, input: nil, cursor: -1]

  @doc "An error without context, as vanilla's `create(...)`."
  def new(key, args \\ []), do: %__MODULE__{message: Text.translatable(key, args)}

  @doc "An error at the reader's cursor, as vanilla's `createWithContext(reader, ...)`."
  def with_context(key, args, %Reader{} = reader),
    do: %__MODULE__{
      message: Text.translatable(key, args),
      input: Reader.string(reader),
      cursor: reader.cursor
    }

  @doc "A ValiMC refusal for syntax vanilla accepts but ValiMC does not implement yet."
  def unsupported(text, %Reader{} = reader),
    do: %__MODULE__{
      message: Text.literal(text),
      input: Reader.string(reader),
      cursor: reader.cursor
    }

  def at(%__MODULE__{} = error, cursor), do: %{error | cursor: cursor}

  def throw!(%__MODULE__{} = error), do: throw({:command_syntax, error})

  def fail!(key, args \\ []), do: throw!(new(key, args))

  @doc "Refuses something ValiMC does not implement yet with a plain red message."
  def refuse!(text), do: throw!(%__MODULE__{message: Text.literal(text)})
  def fail_at!(key, args, reader), do: throw!(with_context(key, args, reader))

  @doc "Runs `fun`, returning `{:ok, value}` or `{:error, error}` for syntax errors."
  def catching(fun) do
    {:ok, fun.()}
  catch
    {:command_syntax, %__MODULE__{} = error} -> {:error, error}
  end

  @doc """
  The red feedback for a failed command: the message and, with context, vanilla's
  gray `...input<--[HERE]` line that suggests the original command on click
  (`Commands.finishParsing`).
  """
  def feedback(%__MODULE__{} = error, command) do
    message = failure(error.message)

    if error.input != nil and error.cursor >= 0 do
      reader = Reader.new(error.input)
      cursor = min(reader.size, error.cursor)

      context =
        Text.empty()
        |> Text.style([{"color", "gray"}, {"click_event", Text.suggest_command("/" <> command)}])
        |> then(&if cursor > 10, do: Text.append(&1, Text.literal("...")), else: &1)
        |> append_text(Reader.slice(reader, max(0, cursor - 10), cursor))
        |> then(fn context ->
          if cursor < reader.size,
            do:
              Text.append(
                context,
                Text.literal(Reader.slice(reader, cursor, reader.size))
                |> Text.style([{"color", "red"}, {"underlined", true}])
              ),
            else: context
        end)
        |> Text.append(
          Text.translatable("command.context.here")
          |> Text.style([{"color", "red"}, {"italic", true}])
        )

      [message, failure(context)]
    else
      [message]
    end
  end

  # `MutableComponent.append(String)` skips empty text.
  defp append_text(component, ""), do: component
  defp append_text(component, text), do: Text.append(component, Text.literal(text))

  @doc "`CommandSourceStack.sendFailure`: the message as a red sibling of an empty text."
  def failure(component), do: Text.empty() |> Text.append(component) |> Text.color("red")
end
