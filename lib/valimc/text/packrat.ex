defmodule Valimc.Text.Packrat do
  @moduledoc """
  A packrat parsing engine with the semantics of vanilla's
  `net.minecraft.util.parsing.packrat` (VMC-053g), which SNBT command arguments
  use. Vanilla's error messages depend on its exact behaviour, so this follows it:

  - terms: sequences restore the cursor on failure, alternatives try each branch
    in a split scope frame and stop after a `cut`, optional terms always succeed,
    repetitions (with or without a trailing separator), lookaheads, markers;
  - named rules are memoised per cursor (failures too) and run in their own
    scope frame; a lookahead silences only its direct terms, not the rules it
    calls;
  - the scope keeps a frame's keys when values are cleared, and a merged branch
    only overwrites a key with a non-nil value;
  - errors are collected at the furthest cursor only (`LongestOnly`), and the
    first command error among them is reported.

  Grammars are maps of rule name to `{:term, term, action}` or
  `{:prim, fun}`. Actions and primitives take and return the parse state.
  """
  alias Valimc.Text.{Error, Reader}

  defstruct [:reader, :rules, frames: [[]], cache: %{}, last: -1, errors: [], silent: false]

  @doc "Parses rule `top` at the reader: `{:ok, value, reader}` or throws the vanilla error."
  def parse(rules, top, %Reader{} = reader) do
    state = %__MODULE__{reader: reader, rules: rules}
    {value, state} = rule(state, top)

    if value != nil do
      {:ok, value, state.reader}
    else
      throw_error(state)
    end
  end

  defp throw_error(state) do
    error =
      state.errors
      |> Enum.reverse()
      |> Enum.find_value(fn
        {:delayed, key, args} ->
          Error.with_context(key, args, Reader.set_cursor(state.reader, state.last))

        %Error{} = error ->
          error

        _ ->
          nil
      end)

    Error.throw!(
      error || Error.with_context("command.exception", ["Failed to parse"], state.reader)
    )
  end

  # ---- state helpers for actions and primitives ----

  def mark(state), do: state.reader.cursor
  def restore(state, cursor), do: %{state | reader: Reader.set_cursor(state.reader, cursor)}

  @doc "Records an error reason at `cursor` (`ErrorCollector.LongestOnly`)."
  def store(%{silent: true} = state, _cursor, _reason), do: state

  def store(state, cursor, reason) do
    cond do
      cursor > state.last -> %{state | last: cursor, errors: [reason]}
      cursor == state.last -> %{state | errors: [reason | state.errors]}
      true -> state
    end
  end

  def get(state, atom) do
    case List.keyfind(hd(state.frames), atom, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  def get(state, atom, default) do
    case List.keyfind(hd(state.frames), atom, 0) do
      {_, value} -> value
      nil -> default
    end
  end

  @doc "`Scope.getAny`: the value of the most recently added of `atoms`."
  def get_any(state, atoms) do
    hd(state.frames)
    |> Enum.reverse()
    |> Enum.find_value(fn {key, value} -> if key in atoms, do: {value} end)
    |> case do
      {value} -> value
      nil -> nil
    end
  end

  def put(%{frames: [frame | rest]} = state, atom, value) do
    frame =
      if List.keymember?(frame, atom, 0),
        do: List.keyreplace(frame, atom, 0, {atom, value}),
        else: frame ++ [{atom, value}]

    %{state | frames: [frame | rest]}
  end

  # ---- rules ----

  @doc "Parses a named rule with memoisation (`CachedParseState.parse`)."
  def rule(state, name) do
    key = {mark(state), name}

    case Map.fetch(state.cache, key) do
      {:ok, :fail} ->
        {nil, state}

      {:ok, {value, after_parse}} ->
        {value, restore(state, after_parse)}

      :error ->
        silent = state.silent
        {value, state} = run(%{state | silent: false}, Map.fetch!(state.rules, name))
        state = %{state | silent: silent}
        entry = if value == nil, do: :fail, else: {value, mark(state)}
        {value, %{state | cache: Map.put(state.cache, key, entry)}}
    end
  end

  defp run(state, {:prim, fun}), do: fun.(state)

  defp run(state, {:term, term, action}) do
    state = %{state | frames: [[] | state.frames]}
    {ok, state, _cut} = term(state, term, false)
    {value, state} = if ok, do: action.(state), else: {nil, state}
    {value, %{state | frames: tl(state.frames)}}
  end

  # ---- terms: {ok, state, cut} ----

  defp term(state, {:chars, chars}, cut) do
    reader = Reader.skip_whitespace(state.reader)
    state = %{state | reader: reader}
    cursor = reader.cursor

    if Reader.can_read?(reader) and accepted?(chars, Reader.peek(reader)) do
      {true, %{state | reader: Reader.skip(reader)}, cut}
    else
      reason = {:delayed, "argument.literal.incorrect", [joined(chars)]}
      state = if Reader.can_read?(reader), do: %{state | reader: Reader.skip(reader)}, else: state
      {false, store(state, cursor, reason), cut}
    end
  end

  defp term(state, {:seq, terms}, cut) do
    mark = mark(state)

    Enum.reduce_while(terms, {true, state, cut}, fn term, {true, state, cut} ->
      case term(state, term, cut) do
        {true, state, cut} -> {:cont, {true, state, cut}}
        {false, state, cut} -> {:halt, {false, restore(state, mark), cut}}
      end
    end)
  end

  defp term(state, {:alt, terms}, cut) do
    mark = mark(state)
    [top | _] = state.frames
    state = %{state | frames: [Enum.map(top, fn {key, _} -> {key, nil} end) | state.frames]}

    result =
      Enum.reduce_while(terms, {:failed, state}, fn term, {:failed, state} ->
        case term(state, term, false) do
          {true, state, _} ->
            {:halt, {:ok, merge(state)}}

          {false, state, branch_cut} ->
            [frame | rest] = state.frames

            state =
              restore(
                %{state | frames: [Enum.map(frame, fn {key, _} -> {key, nil} end) | rest]},
                mark
              )

            if branch_cut, do: {:halt, {:failed, state}}, else: {:cont, {:failed, state}}
        end
      end)

    case result do
      {:ok, state} -> {true, state, cut}
      {:failed, state} -> {false, %{state | frames: tl(state.frames)}, cut}
    end
  end

  defp term(state, {:opt, inner}, cut) do
    mark = mark(state)

    case term(state, inner, cut) do
      {true, state, cut} -> {true, state, cut}
      {false, state, cut} -> {true, restore(state, mark), cut}
    end
  end

  defp term(state, {:rep, name, list}, cut), do: repeat(state, name, list, [], cut)

  defp term(state, {:rep_sep, name, list, separator}, cut) do
    list_mark = mark(state)
    {elements, state} = repeat_sep(state, name, separator, [], true, cut)

    case elements do
      :fail -> {false, restore(state, list_mark), cut}
      elements -> {true, put(state, list, Enum.reverse(elements)), cut}
    end
  end

  defp term(state, {:look, inner, positive}, cut) do
    mark = mark(state)
    silent = state.silent
    {result, state, cut} = term(%{state | silent: true}, inner, cut)
    {positive == result, restore(%{state | silent: silent}, mark), cut}
  end

  defp term(state, {:marker, atom, value}, cut), do: {true, put(state, atom, value), cut}
  defp term(state, :cut, _cut), do: {true, state, true}
  defp term(state, {:fail, reason}, cut), do: {false, store(state, mark(state), reason), cut}

  defp term(state, {:ref, name, store_as}, cut) do
    case rule(state, name) do
      {nil, state} -> {false, state, cut}
      {value, state} -> {true, put(state, store_as, value), cut}
    end
  end

  defp repeat(state, name, list, acc, cut) do
    entry = mark(state)

    case rule(state, name) do
      {nil, state} -> {true, put(restore(state, entry), list, Enum.reverse(acc)), cut}
      {value, state} -> repeat(state, name, list, [value | acc], cut)
    end
  end

  # Trailing separators are allowed in every SNBT repetition.
  defp repeat_sep(state, name, separator, acc, first, cut) do
    before_separator = mark(state)

    {separated, state} =
      if first do
        {true, state}
      else
        {ok, state, _} = term(state, separator, cut)
        {ok, state}
      end

    if not separated do
      {acc, restore(state, before_separator)}
    else
      after_separator = mark(state)

      case rule(state, name) do
        {nil, state} -> {acc, restore(state, after_separator)}
        {value, state} -> repeat_sep(state, name, separator, [value | acc], false, cut)
      end
    end
  end

  # Merge the branch frame into its parent (`Scope.mergeFrame`).
  defp merge(%{frames: [branch, parent | rest]} = state) do
    merged =
      Enum.reduce(Enum.with_index(branch), parent, fn {{key, value}, index}, parent ->
        case Enum.at(parent, index) do
          {^key, _} when value == nil -> parent
          {^key, _} -> List.replace_at(parent, index, {key, value})
          _ -> List.keystore(parent, key, 0, {key, value})
        end
      end)

    %{state | frames: [merged | rest]}
  end

  defp accepted?(chars, c) when is_list(chars), do: c in chars
  defp accepted?(fun, c) when is_function(fun, 1), do: fun.(c)

  defp joined(chars) when is_list(chars),
    do: Enum.map_join(chars, "|", &:unicode.characters_to_binary(<<&1::16>>, :utf16, :utf8))

  defp joined(_fun), do: ""
end
