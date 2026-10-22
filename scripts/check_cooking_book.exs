raw = System.argv() |> hd() |> File.read!() |> JSON.decode!()
hex = fn packet -> packet |> elem(1) |> IO.iodata_to_binary() |> Base.encode16(case: :lower) end

for row <- raw["entries"] do
  actual =
    Valimc.Blocks.CookingRecipeBook.packet(MapSet.new([row["recipe"]]), false, true) |> hex.()

  true = actual == row["single"]
end

all = MapSet.new(raw["entries"], & &1["recipe"])
true = hex.(Valimc.Blocks.CookingRecipeBook.packet(all, true, false)) == raw["quiet_all"]
true = hex.(Valimc.Blocks.CookingRecipeBook.packet(all, false, true)) == raw["notify_all"]
true = hex.(Valimc.Blocks.CookingRecipeBook.packet(MapSet.new(), true, false)) == raw["empty"]

IO.puts(
  "PASS: 107 single unlocks, complete quiet/notification batches and empty native recipe-book packet bodies"
)
