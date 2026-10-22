defmodule Valimc.Commands.Parser.ItemPredicate do
  @moduledoc """
  The `item_predicate` argument (VMC-053g): vanilla's `ComponentPredicateParser`
  grammar on `Valimc.Text.Packrat` — `id`, `#tag` or `*`, then optional
  `[...]` conditions joined by `,` (all) and `|` (any), negated with `!`:
  `component`, `component=value` and `predicate~value`.

  Matching supports item, tag, `count`, component presence and the component
  values `Valimc.Protocol.ItemData.decode_component/2` decodes; other value tests are refused
  with a ValiMC message.
  """
  alias Valimc.Text.{Error, Packrat, Reader, Snbt}
  alias Valimc.Protocol.Registries
  import Packrat, only: [get: 2, get_any: 2, mark: 1, store: 3]

  def parse(reader) do
    {:ok, predicates, reader} = Packrat.parse(rules(), :top, reader)
    {{:all, predicates}, reader}
  end

  defp rules do
    case :persistent_term.get({__MODULE__, :rules}, nil) do
      nil ->
        rules = build()
        :persistent_term.put({__MODULE__, :rules}, rules)
        rules

      rules ->
        rules
    end
  end

  defp chars(text), do: {:chars, String.to_charlist(text)}
  defp ref(name), do: {:ref, name, name}

  defp build do
    %{
      top:
        {:term,
         {:alt,
          [
            {:seq, [ref(:type), chars("["), :cut, {:opt, ref(:conditions)}, chars("]")]},
            ref(:type)
          ]},
         fn state ->
           type = get(state, :type)
           conditions = get(state, :conditions) || []
           {if(type == :any, do: [], else: [type]) ++ conditions, state}
         end},
      type:
        {:term,
         {:alt, [ref(:element_type), {:seq, [chars("#"), :cut, ref(:tag_type)]}, ref(:any_type)]},
         fn state -> {get_any(state, [:element_type, :tag_type]) || :any, state} end},
      any_type: {:term, chars("*"), fn state -> {:any, state} end},
      element_type: {:prim, lookup(&element/2)},
      tag_type: {:prim, lookup(&tag/2)},
      conditions:
        {:term, {:seq, [ref(:alternatives), {:opt, {:seq, [chars(","), ref(:conditions)]}}]},
         fn state ->
           {[{:any_of, get(state, :alternatives)} | get(state, :conditions) || []], state}
         end},
      alternatives:
        {:term, {:seq, [ref(:term), {:opt, {:seq, [chars("|"), ref(:alternatives)]}}]},
         fn state -> {[get(state, :term) | get(state, :alternatives) || []], state} end},
      term:
        {:term, {:alt, [ref(:test), {:seq, [chars("!"), ref(:negation)]}]},
         fn state -> {get_any(state, [:test, :negation]), state} end},
      negation: {:term, ref(:test), fn state -> {{:not, get(state, :test)}, state} end},
      test:
        {:term,
         {:alt,
          [
            {:seq, [ref(:component_type), chars("="), :cut, ref(:tag)]},
            {:seq, [ref(:predicate_type), chars("~"), :cut, ref(:tag)]},
            ref(:component_type)
          ]}, &test/1},
      component_type: {:prim, lookup(&component/2)},
      predicate_type: {:prim, lookup(&predicate/2)},
      id: {:prim, &id/1},
      tag: {:prim, &tag_value/1}
    }
  end

  # `IdentifierParseRule`: a non-empty identifier, else nothing (no error).
  defp id(state) do
    reader = Reader.skip_whitespace(state.reader)

    case Error.catching(fn -> Valimc.Text.Identifier.read(reader) end) do
      {:ok, {_id, after_id}} when after_id.cursor == reader.cursor ->
        {nil, %{state | reader: reader}}

      {:ok, {id, after_id}} ->
        {id, %{state | reader: after_id}}

      {:error, _} ->
        {nil, %{state | reader: reader}}
    end
  end

  # `ResourceLookupRule`: an identifier, then the context's lookup error (with
  # the reader after the identifier) or `argument.id.invalid`, stored at the start.
  defp lookup(validate) do
    fn state ->
      state = %{state | reader: Reader.skip_whitespace(state.reader)}
      start = mark(state)

      case Packrat.rule(state, :id) do
        {nil, state} ->
          {nil, store(state, start, {:delayed, "argument.id.invalid", []})}

        {id, state} ->
          case validate.(id, state.reader) do
            {:ok, value} -> {value, state}
            {:error, error} -> {nil, store(state, start, error)}
          end
      end
    end
  end

  defp element(id, reader) do
    case Registries.item_id(id) do
      nil -> {:error, Error.with_context("argument.item.id.invalid", [id], reader)}
      item_id -> {:ok, {:item, item_id}}
    end
  end

  defp tag(id, reader) do
    case Registries.tag("minecraft:item", id) do
      nil -> {:error, Error.with_context("arguments.item.tag.unknown", [id], reader)}
      members -> {:ok, {:tag, MapSet.new(members)}}
    end
  end

  defp component("minecraft:count", _reader), do: {:ok, {:component, "minecraft:count"}}

  defp component(id, reader) do
    if Valimc.Commands.Facts.item_component?(id),
      do: {:ok, {:component, id}},
      else: {:error, Error.with_context("arguments.item.component.unknown", [id], reader)}
  end

  defp predicate("minecraft:count", _reader), do: {:ok, {:predicate, "minecraft:count"}}

  defp predicate(id, reader) do
    cond do
      Valimc.Commands.Facts.item_predicate?(id) -> {:ok, {:predicate, id}}
      Registries.component?(id) -> {:ok, {:exists, id}}
      true -> {:error, Error.with_context("arguments.item.predicate.unknown", [id], reader)}
    end
  end

  # `TagParseRule`: SNBT in its own parser; its error is stored at the start.
  defp tag_value(state) do
    reader = Reader.skip_whitespace(state.reader)
    state = %{state | reader: reader}

    case Error.catching(fn -> Snbt.parse(reader) end) do
      {:ok, {value, reader}} -> {value, %{state | reader: reader}}
      {:error, error} -> {nil, store(state, mark(state), error)}
    end
  end

  defp test(state) do
    predicate = get(state, :predicate_type)
    component = get(state, :component_type)
    value = get(state, :tag)

    result =
      cond do
        predicate != nil -> predicate_test(predicate, value, state.reader)
        value != nil -> component_test(component, value, state.reader)
        true -> {:ok, {:has, elem(component, 1)}}
      end

    case result do
      {:ok, test} -> {test, state}
      {:error, error} -> {nil, store(state, mark(state), error)}
    end
  end

  defp component_test({:component, "minecraft:count"}, value, reader),
    do: count(value, reader, "arguments.item.component.malformed")

  defp component_test({:component, id}, value, reader) do
    case Valimc.Protocol.ItemData.decode_component(id, value) do
      {:ok, decoded} ->
        {:ok, {:equals, id, decoded}}

      {:error, message} ->
        {:error, Error.with_context("arguments.item.component.malformed", [id, message], reader)}

      :unsupported ->
        {:error,
         Error.unsupported("Testing the item component #{id} is not supported yet", reader)}
    end
  end

  defp predicate_test({:predicate, "minecraft:count"}, value, reader),
    do: count(value, reader, "arguments.item.predicate.malformed")

  defp predicate_test({:exists, id}, _value, _reader), do: {:ok, {:has, id}}

  defp predicate_test({:predicate, id}, _value, reader),
    do: {:error, Error.unsupported("The item predicate #{id} is not supported yet", reader)}

  # `MinMaxBounds.Ints.CODEC`: a number, or `{min:..,max:..}`.
  defp count(value, reader, key) do
    case value do
      {type, n} when type in [:byte, :short, :int, :long] ->
        {:ok, {:count, n, n}}

      {:compound, fields} ->
        min = number(fields["min"])
        max = number(fields["max"])

        if min != nil and max != nil and min > max,
          do:
            {:error,
             Error.with_context(
               key,
               [
                 "minecraft:count",
                 "Swapped bounds in range: Optional[#{min}] is higher than Optional[#{max}]"
               ],
               reader
             )},
          else: {:ok, {:count, min, max}}

      other ->
        message =
          "Failed to parse either. First: Not a map: #{Snbt.to_string(other)}; Second: Not a number"

        {:error, Error.with_context(key, ["minecraft:count", message], reader)}
    end
  end

  defp number({type, n}) when type in [:byte, :short, :int, :long], do: n
  defp number(_), do: nil

  # ---- matching ----

  def matches?({:all, predicates}, stack), do: Enum.all?(predicates, &test?(&1, stack))

  defp test?({:item, id}, stack), do: stack.item_id == id
  defp test?({:tag, members}, stack), do: MapSet.member?(members, stack.item_id)
  defp test?({:any_of, tests}, stack), do: Enum.any?(tests, &test?(&1, stack))
  defp test?({:not, test}, stack), do: not test?(test, stack)

  defp test?({:count, min, max}, stack),
    do: (min == nil or stack.count >= min) and (max == nil or stack.count <= max)

  defp test?({:has, "minecraft:count"}, _stack), do: true
  defp test?({:has, id}, stack), do: Valimc.Protocol.ItemStack.has_component?(stack, id)

  defp test?({:equals, id, value}, stack),
    do: Valimc.Protocol.ItemStack.component(stack, id) == value
end
