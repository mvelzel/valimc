alias Valimc.Data.NBT
alias Valimc.Protocol.{ItemData, ItemStack}

# Mojang's component values (`ItemComponentOracle generate`) in both formats:
# ValiMC reads each, re-encodes the network bytes exactly, reads the data form to
# the same value and writes both back for Mojang to decode (VMC-004b).
[input, output] = System.argv()
fixtures = :json.decode(File.read!(input))
hex = &Base.decode16!(&1, case: :lower)

{checked, skipped} =
  Enum.split_with(fixtures, &(&1["component"] in ItemStack.supported_components()))

rows =
  for fixture <- checked do
    name = fixture["component"]
    bytes = hex.(fixture["stream"])

    value =
      try do
        {value, <<>>} = ItemStack.take_component(name, bytes)
        value
      catch
        kind, reason -> raise "#{name} #{fixture["stream"]}: #{inspect({kind, reason})}"
      end

    encoded = name |> ItemStack.encode_component_value(value) |> IO.iodata_to_binary()
    # Exact bytes, except that a nested patch's entries may come in another order
    # (Mojang writes a component map in its iteration order, ValiMC by type id).
    if encoded != bytes do
      {again, <<>>} = ItemStack.take_component(name, encoded)

      if ItemStack.component_identity(name, again) != ItemStack.component_identity(name, value),
        do: raise("#{name}: network bytes differ for #{inspect(value)}")
    end

    data =
      case fixture["data"] do
        nil ->
          []

        data ->
          {:ok, tag} = NBT.decode(hex.(data))
          read = ItemData.component_value(name, tag)

          if ItemStack.component_identity(name, read) != ItemStack.component_identity(name, value),
            do:
              raise(
                "#{name}: data form #{inspect(tag)} reads as #{inspect(read)}, not #{inspect(value)}"
              )

          written =
            name |> ItemData.component_tag(read) |> NBT.encode() |> IO.iodata_to_binary()

          [{"data", Base.encode16(written, case: :lower)}]
      end

    Map.new([
      {"index", fixture["index"]},
      {"stream", Base.encode16(encoded, case: :lower)} | data
    ])
  end

File.write!(output, :json.encode(rows))

types = checked |> Enum.map(& &1["component"]) |> Enum.uniq() |> length()
others = skipped |> Enum.map(& &1["component"]) |> Enum.uniq() |> Enum.sort()
# Every 26.3 component type has a codec (VMC-004b7).
if others != [], do: raise("Component types without a codec: #{Enum.join(others, ", ")}")

IO.puts(
  "PASS: ValiMC read and re-encoded #{length(rows)} Mojang values of #{types} component types"
)
