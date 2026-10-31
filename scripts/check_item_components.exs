alias Valimc.Data.NBT
alias Valimc.Protocol.{ComponentSchema, ComponentSchemas}

# Mojang's component values (`ItemComponentOracle generate`) in both formats:
# ValiMC reads each, re-encodes the network bytes exactly, reads the data form to
# the same value and writes both back for Mojang to decode (VMC-004b).
[input, output] = System.argv()
fixtures = :json.decode(File.read!(input))
hex = &Base.decode16!(&1, case: :lower)

{checked, skipped} =
  Enum.split_with(fixtures, &(ComponentSchemas.schema(&1["component"]) != nil))

rows =
  for fixture <- checked do
    name = fixture["component"]
    schema = ComponentSchemas.schema(name)
    bytes = hex.(fixture["stream"])

    value =
      try do
        {value, <<>>} = ComponentSchema.take(schema, bytes)
        value
      catch
        kind, reason -> raise "#{name} #{fixture["stream"]}: #{inspect({kind, reason})}"
      end

    encoded = schema |> ComponentSchema.encode(value) |> IO.iodata_to_binary()
    if encoded != bytes, do: raise("#{name}: network bytes differ for #{inspect(value)}")

    data =
      case fixture["data"] do
        nil ->
          []

        data ->
          {:ok, tag} = NBT.decode(hex.(data))
          read = ComponentSchema.from_tag(schema, tag)

          if ComponentSchema.identity_key(schema, read) !=
               ComponentSchema.identity_key(schema, value),
             do:
               raise(
                 "#{name}: data form #{inspect(tag)} reads as #{inspect(read)}, not #{inspect(value)}"
               )

          written =
            schema |> ComponentSchema.to_tag(read) |> NBT.encode() |> IO.iodata_to_binary()

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
  "PASS: ValiMC read and re-encoded #{length(rows)} Mojang values of #{types} schema component types" <>
    if(others == [], do: "", else: "; without a schema yet: #{Enum.join(others, ", ")}")
)
