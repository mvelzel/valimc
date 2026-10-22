defmodule Valimc.Data.BlockFacts do
  @moduledoc """
  The per-state block fact table (`BlockFactsOracle`, VMC-077d): one column per
  concern with one value per state, shared by Elixir and the Rust core.

  Columns: whole-state flags (air, sturdy and full faces, decoration's
  predicates, flammable, large collision), the collision shape or the context
  it needs, motion, fluid, fluid boundary, climbing, inside behaviour, hazard,
  landing, mining, placement replaceability, heightmap predicates, sky-source
  edge classes, light (emission, dampening and face occlusion classes) and
  redstone signals (the Rust core's alone). The
  oracle's comment describes each. State ids are trusted: they come from the
  world or the registry, and an id outside the table raises. `install!/0`
  gives the Rust core the columns it reads.
  """
  alias Valimc.Data.Float32
  import Bitwise
  use Valimc.Data.Facts, "registry/block_facts.json"
  alias Valimc.Native
  alias Valimc.Data.Box

  @count @facts["state_count"]
  unless @count == Valimc.Data.Blocks.state_count(),
    do: raise("Block facts and the block registry differ in state count")

  columns = @facts["columns"]

  # A column's per-state values as a binary of one or two bytes per state.
  states = fn name ->
    bytes = Base.decode16!(columns[name]["states"], case: :lower)
    width = div(byte_size(bytes), @count)

    unless width in [1, 2] and byte_size(bytes) == width * @count,
      do: raise("Block fact column #{name} does not cover every state")

    bytes
  end

  palette = fn name, decode ->
    values = columns[name]["palette"] |> Enum.map(decode) |> List.to_tuple()
    bytes = states.(name)

    indexes =
      if byte_size(bytes) == @count,
        do: :binary.bin_to_list(bytes),
        else: for(<<i::16 <- bytes>>, do: i)

    unless Enum.max(indexes) < tuple_size(values),
      do: raise("Block fact column #{name} indexes past its palette")

    values
  end

  @bits @facts["flag_bits"]
        |> Enum.with_index()
        |> Map.new(fn {n, i} -> {String.to_atom(n), i} end)
  @flag_states states.("flags")
  @flags palette.("flags", & &1)

  @shape_states states.("shape")
  @boundary_states states.("boundary")
  @motion_states states.("motion")
  @motion palette.("motion", fn m ->
            %{
              friction: m["friction"],
              speed_factor: m["speed_factor"],
              jump_factor: m["jump_factor"],
              bounciness: m["bounciness"],
              suppresses_bounce: m["suppresses_bounce"],
              support_holds_y: m["support_holds_y"],
              speed_override: m["speed_override"]
            }
          end)

  @fluid_states states.("fluid")
  @fluids palette.("fluid", fn f ->
            %{
              kind: elem({:empty, :water, :lava}, f["kind"]),
              amount: f["amount"],
              height: f["height"],
              source: f["source"],
              falling: f["falling"]
            }
          end)
  @remains palette.("fluid", & &1["replacement"])

  @climb_states states.("climb")
  @climbs palette.("climb", fn c ->
            %{
              climbable: c["climbable"],
              glide_through: c["glide_through"],
              scaffolding: c["scaffolding"],
              ladder_facing: c["ladder_facing"],
              trapdoor_facing: c["trapdoor_facing"],
              trapdoor_open: c["trapdoor_open"]
            }
          end)

  @inside_kinds ~w(none fire soul_fire powder_snow cobweb berry_bush)a
  @inside_states states.("inside")
  @insides palette.("inside", fn i ->
             kind = String.to_atom(i["kind"])
             unless kind in @inside_kinds, do: raise("Unknown inside kind #{kind}")

             shape =
               case i["shape"] do
                 nil ->
                   :full

                 "context" ->
                   :context

                 boxes ->
                   boxes = Enum.map(boxes, &List.to_tuple/1)
                   unless Enum.all?(boxes, &Box.valid?/1), do: raise("Invalid inside shape")
                   boxes
               end

             %{kind: kind, shape: shape}
           end)

  @hazard_states states.("hazard")
  @hazards palette.("hazard", fn
             nil -> nil
             %{"kind" => kind, "value" => value} -> {String.to_atom(kind), value}
           end)

  @landing_states states.("landing")
  @landings palette.("landing", fn pair ->
              pair
              |> Enum.map(fn
                nil ->
                  nil

                rule ->
                  %{
                    distance_scale: rule["distance_scale"],
                    distance_offset: rule["distance_offset"],
                    multiplier: rule["multiplier"],
                    source: String.to_atom(rule["source"])
                  }
              end)
              |> List.to_tuple()
            end)

  @mining_states states.("mining")
  @minings palette.("mining", fn m ->
             hardness = m["hardness"]

             unless Float32.round(hardness) == hardness,
               do: raise("Noncanonical mining hardness")

             {hardness, m["requires_correct_tool"]}
           end)

  @replaceability states.("replaceability")
  @heightmap_states states.("heightmap")
  @heightmap_bits @facts["heightmap_types"]
                  |> Enum.with_index()
                  |> Map.new(fn {name, i} ->
                    {name |> String.downcase() |> String.to_atom(), i}
                  end)
  @light states.("light")
  @sky states.("sky")
  @sky_classes columns["sky"]["classes"]
  @sky_pairs Base.decode16!(columns["sky"]["pairs"], case: :lower)
  @light_faces for d <- ~w(down up north south west east),
                   column = columns["light_" <> d],
                   do:
                     {states.("light_" <> d), column["classes"],
                      Base.decode16!(column["occludes"], case: :lower)}

  # Signals as the Rust core packs them: `getSignal` toward direction d at bits
  # 4d, `getDirectSignal` at 24 + 4d, bit 48 for a signal that reads the level.
  # The oracle keeps the palette under 256, so the column has a byte per state.
  @signal_states states.("signal")
  @signals palette.("signal", fn
             %{"context" => _} ->
               1 <<< 48

             %{"signal" => signal, "direct" => direct} ->
               (signal ++ direct)
               |> Enum.with_index()
               |> Enum.reduce(0, fn {value, i}, acc -> acc ||| value <<< (4 * i) end)
           end)
  unless byte_size(@signal_states) == @count, do: raise("Signal palette past one byte")

  @block_entity_types @facts["block_entity_types"]

  # What the physics kernel reads (VMC-077l), as `block_facts_init` takes it.
  native_shape = fn %{"axes" => axes, "sizes" => sizes, "bits" => bits} ->
    {Enum.map(axes, fn a -> Enum.map(a, &(&1 * 1.0)) end), sizes,
     Base.decode16!(bits, case: :lower)}
  end

  empty_shape = {[[0.0], [0.0], [0.0]], [0, 0, 0], <<>>}

  @native_shapes Enum.map(columns["shape"]["palette"], fn
                   %{"context" => _, "shape" => shape, "max_offset" => limit} ->
                     {:offset, native_shape.(shape), false, limit * 1.0}

                   %{"context" => "minecraft:scaffolding"} ->
                     {:scaffolding, empty_shape, false, 0.0}

                   %{"context" => "minecraft:powder_snow"} ->
                     {:powder_snow, empty_shape, false, 0.0}

                   %{"context" => "minecraft:moving_piston"} ->
                     {:moving_piston, empty_shape, false, 0.0}

                   %{"context" => name} ->
                     unless String.ends_with?(name, "shulker_box"),
                       do: raise("Unknown collision context #{name}")

                     {:shulker_box, empty_shape, false, 0.0}

                   geometry ->
                     {:fixed, native_shape.(geometry), geometry["full_block"], 0.0}
                 end)
  contextual = @facts["contextual_shapes"]

  @native_contextual %{
    scaffolding_stable: native_shape.(contextual["scaffolding_stable"]),
    scaffolding_bottom: native_shape.(contextual["scaffolding_unstable_bottom"]),
    scaffolding_below_height: contextual["scaffolding_below_height"] * 1.0,
    powder_snow_falling: native_shape.(contextual["powder_snow_falling"])
  }
  @native_scaffolding for id <- Valimc.Data.Blocks.states("scaffolding"),
                          properties = Map.new(Valimc.Data.Blocks.properties(id)),
                          do:
                            {id, String.to_integer(properties["distance"]),
                             properties["bottom"] == "true"}
  @native_motion Enum.map(columns["motion"]["palette"], fn m ->
                   {{m["friction"] * 1.0, m["speed_factor"] * 1.0, m["jump_factor"] * 1.0,
                     m["bounciness"] * 1.0},
                    {m["suppresses_bounce"], m["support_holds_y"], m["speed_override"]}}
                 end)
  @native_fluids Enum.map(columns["fluid"]["palette"], fn f ->
                   {f["kind"], f["amount"], f["height"] * 1.0, f["source"], f["falling"]}
                 end)
  @native_boundaries Enum.map(columns["boundary"]["palette"], fn b ->
                       context =
                         case b["context"] do
                           "none" -> 0
                           "piston" -> 1
                           "shulker" -> 2
                         end

                       {b["blocks_flow"], b["ice"], context}
                     end)

  def count, do: @count

  @doc "The flag bit set of a state."
  def flags(state) do
    skip = 2 * state
    <<_::binary-size(^skip), index::16, _::binary>> = @flag_states
    elem(@flags, index)
  end

  @doc "Whether a state has flag `name` (one of the oracle's `flag_bits`)."
  def flag?(state, name), do: (flags(state) >>> Map.fetch!(@bits, name) &&& 1) == 1

  def air?(state), do: (flags(state) &&& 1) == 1

  @doc "Sturdy full faces as a mask over vanilla `Direction` order (down, up, north, south, west, east)."
  def sturdy_faces(state), do: flags(state) >>> 5 &&& 63

  def motion(state), do: elem(@motion, :binary.at(@motion_states, state))

  @doc "The contained fluid: kind (`:empty`, `:water`, `:lava`), amount, height, source, falling."
  def fluid(state), do: elem(@fluids, :binary.at(@fluid_states, state))

  @doc "What base block removal leaves: the state's fluid as a block (air when it has none)."
  def fluid_remains(state), do: elem(@remains, :binary.at(@fluid_states, state))

  def climb(state), do: elem(@climbs, :binary.at(@climb_states, state))

  @doc """
  What standing inside does (`:fire`, `:soul_fire`, `:powder_snow`, `:cobweb`,
  `:berry_bush` or `:none`) and the inside shape: `:full`, `:context` (powder
  snow) or block-local boxes.
  """
  def inside(state), do: elem(@insides, :binary.at(@inside_states, state))

  @doc "The slowing block kind (`:cobweb`, `:berry_bush`, `:powder_snow`) or `:none`."
  def stuck(state) do
    case inside(state).kind do
      kind when kind in [:cobweb, :berry_bush, :powder_snow] -> kind
      _ -> :none
    end
  end

  @doc "The immediate hazard: `{:magma | :campfire | :cactus | :berry, value}` or nil."
  def hazard(state), do: elem(@hazards, :binary.at(@hazard_states, state))

  @doc "The `fallOn` damage rules without and with sneaking (nil: no damage call)."
  def landing(state), do: elem(@landings, :binary.at(@landing_states, state))

  @doc "`{hardness, requires correct tool}`."
  def mining(state), do: elem(@minings, :binary.at(@mining_states, state))

  @doc "Placement on a click: 0 another rule, 1 never replaced, 2 replaced, 3 a slab."
  def replaceability(state), do: :binary.at(@replaceability, state)

  @doc "The heightmap predicates as a mask (bit order of `heightmap_types`)."
  def heightmap(state), do: :binary.at(@heightmap_states, state)

  def heightmap?(state, type),
    do: (heightmap(state) >>> Map.fetch!(@heightmap_bits, type) &&& 1) == 1

  @doc "Whether a sky source stops between `above` and `below` (`isEdgeOccluded`)."
  def sky_blocked?(above, below) do
    offset = :binary.at(@sky, above) * @sky_classes + :binary.at(@sky, below)
    (:binary.at(@sky_pairs, div(offset, 8)) >>> rem(offset, 8) &&& 1) == 1
  end

  @doc "The block entity type each block with one creates, by block name."
  def block_entity_types, do: @block_entity_types

  @doc """
  Install the table in the Rust core once per VM (later calls do nothing): the
  flags, heightmap predicates, the fluid as vanilla's fluid registry id, its
  level and what removal leaves, and the light and sky columns. The storage flags, the light engine and
  worldgen's block table read only this install.
  """
  def install! do
    if not :persistent_term.get({__MODULE__, :installed}, false) do
      case Native.block_facts_init(native_columns()) do
        :ok -> :persistent_term.put({__MODULE__, :installed}, true)
        other -> raise "block fact installation failed: #{inspect(other)}"
      end
    end

    :ok
  end

  defp native_columns do
    states = 0..(@count - 1)

    fluids =
      for id <- states do
        fluid = fluid(id)

        kind =
          case {fluid.kind, fluid.source} do
            {:empty, _} -> 0
            {:water, false} -> 1
            {:water, true} -> 2
            {:lava, false} -> 3
            {:lava, true} -> 4
          end

        {kind, fluid.amount + if(fluid.falling, do: 16, else: 0)}
      end

    {faces, classes, occludes} =
      Enum.reduce(Enum.reverse(@light_faces), {[], [], []}, fn {s, n, o}, {fs, ns, os} ->
        {[s | fs], [n | ns], [o | os]}
      end)

    %{
      flags: for(id <- states, into: <<>>, do: <<flags(id)::64>>),
      heightmaps: @heightmap_states,
      fluid: for({kind, _} <- fluids, into: <<>>, do: <<kind>>),
      fluid_level: for({_, level} <- fluids, into: <<>>, do: <<level>>),
      fluid_remains: for(id <- states, into: <<>>, do: <<fluid_remains(id)::16>>),
      signal: for(<<index <- @signal_states>>, into: <<>>, do: <<elem(@signals, index)::64>>),
      light: @light,
      light_faces: faces,
      light_classes: classes,
      light_occludes: occludes,
      sky: @sky,
      sky_classes: @sky_classes,
      sky_pairs: @sky_pairs,
      physics:
        Map.merge(@native_contextual, %{
          shape_states: @shape_states,
          shapes: @native_shapes,
          scaffolding: @native_scaffolding,
          motion_states: @motion_states,
          motion: @native_motion,
          fluid_states: @fluid_states,
          fluids: @native_fluids,
          boundary_states: @boundary_states,
          boundaries: @native_boundaries,
          climb_states: @climb_states,
          climbs: native_climbs(),
          inside_states: @inside_states,
          insides: native_insides(),
          hazard_states: @hazard_states,
          hazards: native_hazards(),
          poses: Valimc.Data.PlayerPose.native_dimensions()
        })
    }
  end

  defp native_climbs,
    do:
      for(
        c <- Tuple.to_list(@climbs),
        do:
          {c.climbable, c.glide_through, c.scaffolding, c.ladder_facing, c.trapdoor_facing,
           c.trapdoor_open}
      )

  defp native_insides,
    do:
      for(
        i <- Tuple.to_list(@insides),
        do: {Enum.find_index(@inside_kinds, &(&1 == i.kind)), i.shape}
      )

  defp native_hazards do
    for h <- Tuple.to_list(@hazards) do
      case h do
        nil -> {0, 0.0}
        {:magma, value} -> {1, value * 1.0}
        {:campfire, value} -> {2, value * 1.0}
        {:cactus, value} -> {3, value * 1.0}
        {:berry, value} -> {4, value * 1.0}
      end
    end
  end
end
