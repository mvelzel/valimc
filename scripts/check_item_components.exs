alias Valimc.Data.NBT
alias Valimc.Protocol.{ItemData, ItemStack}

# Mojang's component values (`ItemComponentOracle generate`) in both formats:
# ValiMC reads each, re-encodes the network bytes exactly, reads the data form to
# the same value and writes both back for Mojang to decode (VMC-004b).
[input, output] = System.argv()
# Network codecs whose data form is still to come (VMC-004b6).
data_gaps = ["minecraft:charged_projectiles"]
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
    if encoded != bytes, do: raise("#{name}: network bytes differ for #{inspect(value)}")

    data =
      case name not in data_gaps and fixture["data"] do
        falsy when falsy in [nil, false] ->
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

IO.puts(
  "PASS: ValiMC read and re-encoded #{length(rows)} Mojang values of #{types} component types" <>
    if(others == [], do: "", else: "; without a codec yet: #{Enum.join(others, ", ")}")
)
