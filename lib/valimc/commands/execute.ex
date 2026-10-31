defmodule Valimc.Commands.Execute do
  @moduledoc """
  `/execute` (`ExecuteCommand`, VMC-083) with its `in`, `positioned`, `at`,
  `as` and `run` branches. Each modifier changes the command source: `in`
  its dimension, `positioned` its position (or an entity's), `at` an
  entity's position, rotation and dimension, `as` the player it runs as; a
  selector forks it once per entity, none running nothing. `run` runs the
  rest of the line once per source. Conditions, `store`, `summon`, `on` and
  the other modifiers wait, and `as` takes players only.
  """
  alias Valimc.Commands.Parser.Dispatcher.Context
  alias Valimc.Commands.{Source, Targets}
  alias Valimc.Text.Error
  alias Valimc.World.Dimension

  @doc "The vanilla paths of `/execute` that run (`Valimc.Commands.Parser.Tree`'s branches)."
  def branches,
    do: [
      ~w(execute run),
      ~w(execute in dimension),
      ~w(execute positioned pos),
      ~w(execute positioned as targets),
      ~w(execute at targets),
      ~w(execute as targets)
    ]

  @doc """
  Runs the command a parse ends in (`handler` with its `arguments`) once for
  each source the parse's modifiers make from `source`: the sum of their
  integer results.
  """
  def fork({%Context{} = context, {module, function}, arguments}, source) do
    context
    |> sources(source)
    |> Enum.map(&apply(module, function, [arguments, &1]))
    |> Enum.reduce(0, fn result, sum -> if is_integer(result), do: sum + result, else: sum end)
  end

  # Every context but the last is one modifier (or `run`), redirecting on,
  # or an alias (`tp`) redirecting to its command.
  defp sources(%Context{child: nil}, source), do: [source]

  defp sources(%Context{nodes: [{%{path: [name | _]}, _} | _], child: child}, source)
       when name != "execute",
       do: sources(child, source)

  defp sources(%Context{child: child} = context, source) do
    names = for {node, _} <- context.nodes, node.name != "execute", do: node.name
    arguments = Map.new(context.arguments, fn {name, {value, _range}} -> {name, value} end)

    names
    |> modify(arguments, source)
    |> Enum.flat_map(&sources(child, &1))
  end

  defp modify(["run"], _arguments, source), do: [source]

  defp modify(["in", "dimension"], %{"dimension" => id}, source) do
    case Dimension.parse(id) do
      {:ok, dimension} -> [%{source | dimension: dimension}]
      :error -> Error.fail!("argument.dimension.invalid", [id])
    end
  end

  defp modify(["positioned", "pos"], %{"pos" => pos}, source),
    do: [%{source | position: Source.position(source, pos)}]

  defp modify(["positioned", "as", "targets"], %{"targets" => selector}, source),
    do: for(e <- Targets.entities(source, selector), do: %{source | position: {e.x, e.y, e.z}})

  defp modify(["at", "targets"], %{"targets" => selector}, source) do
    for e <- Targets.entities(source, selector) do
      %{
        source
        | position: {e.x, e.y, e.z},
          rotation: {e.yaw, e.pitch},
          dimension: Map.get(e, :dimension, :overworld)
      }
    end
  end

  defp modify(["as", "targets"], %{"targets" => selector}, source) do
    for e <- Targets.entities(source, selector) do
      if Map.get(e, :kind) == :body,
        do: Error.refuse!("Running as an entity that is not a player is not supported yet")

      %{source | player: e, name: e.name}
    end
  end
end
