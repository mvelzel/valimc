alias Valimc.Protocol.{EntityPackets, ItemStack, PackedVelocity, Wire}
[input, output] = System.argv()
fixtures = :json.decode(File.read!(input))
Code.ensure_loaded!(Valimc.Physics.PlayerPose)

velocities =
  Enum.map(fixtures["velocities"], fn fixture ->
    bytes = PackedVelocity.encode(List.to_tuple(fixture["source"]))
    expected = Base.decode16!(fixture["wire"], case: :lower)
    if bytes != expected, do: raise("Velocity bytes differ: #{fixture["name"]}")
    {:ok, vector} = PackedVelocity.decode(expected)

    if Tuple.to_list(vector) != fixture["decoded"],
      do: raise("Velocity values differ: #{fixture["name"]}")

    %{
      name: fixture["name"],
      wire: Base.encode16(bytes, case: :lower),
      decoded: Tuple.to_list(vector)
    }
  end)

by_name = Map.new(fixtures["velocities"], &{&1["name"], List.to_tuple(&1["source"])})

base = %{
  entity_id: 300,
  uuid: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>,
  x: -3.25,
  y: 64.2,
  z: 1.75,
  pitch: 22.5,
  yaw: -91.0
}

stone = %{
  ItemStack.new("stone", 7)
  | components: %{
      "minecraft:enchantment_glint_override" => true,
      "minecraft:custom_data" => {:compound, %{"probe" => {:string, "entity " <> <<0>> <> "😀é"}}}
    },
    removed: MapSet.new(["minecraft:rarity"])
}

packets =
  Enum.map(fixtures["packets"], fn fixture ->
    name = fixture["name"]

    packet =
      case name do
        "spawn_" <> vector ->
          EntityPackets.spawn_item(Map.put(base, :velocity, by_name[vector]))

        "motion_" <> vector ->
          EntityPackets.motion(300, by_name[vector])

        "angle_" <> angle ->
          EntityPackets.spawn_item(%{
            base
            | x: 0.0,
              y: 64.0,
              z: 0.0,
              pitch: 0.0,
              yaw: String.to_float(angle)
          })

        "metadata" ->
          EntityPackets.metadata(300, item_stack: stone, no_gravity: true, shared_flags: 64)

        "metadata_empty_stack" ->
          EntityPackets.metadata(300, item_stack: nil)

        "metadata_empty" ->
          EntityPackets.metadata(300, [])

        "metadata_clear_flags" ->
          EntityPackets.metadata(300, shared_flags: 0, no_gravity: false)

        "pose_" <> pose ->
          EntityPackets.metadata(300, pose: String.to_existing_atom(pose))

        "pickup" ->
          EntityPackets.pickup(300, 301, 7)

        "remove" ->
          EntityPackets.remove([300, 301])

        "remove_empty" ->
          EntityPackets.remove([])
      end

    {id, payload} = packet
    bytes = IO.iodata_to_binary([Wire.varint(id), payload])

    if name != "metadata" and bytes != Base.decode16!(fixture["wire"], case: :lower),
      do: raise("Entity packet differs: #{name}")

    %{name: name, wire: Base.encode16(bytes, case: :lower)}
  end)

File.write!(output, :json.encode(%{velocities: velocities, packets: packets}))

IO.puts(
  "PASS: Elixir independently encoded #{length(velocities)} packed velocities and #{length(packets)} complete entity packets"
)
