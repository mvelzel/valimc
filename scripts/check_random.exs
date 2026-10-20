# VMC-023a: ValiMC's random sources return vanilla's values (RandomOracle traces).
# Gaussians go through Java's `Math.log`, a platform intrinsic allowed to differ
# from a correctly rounded logarithm, so they are compared within 4 ulps (and the
# inexact ones counted); every other value must be exact. Worldgen draws no
# Gaussians.
import Bitwise

[facts_path] = System.argv()
cases = (facts_path |> File.read!() |> JSON.decode!())["cases"]

ulps = fn a, b ->
  {x, y} = {String.to_integer(a, 16), String.to_integer(b, 16)}
  # Same sign for these values; the bit distance is the ulp distance.
  abs(x - y) + if((x ^^^ y) >>> 63 == 1, do: 1 <<< 62, else: 0)
end

{mismatches, inexact, gaussians} =
  for %{"kind" => kind, "seed" => seed, "ops" => ops, "results" => expected} <- cases,
      {:ok, actual} = Valimc.Native.worldgen_random_trace(kind, String.to_integer(seed), ops),
      {op, a, b} <- Enum.zip([ops, actual, expected]),
      reduce: {[], 0, 0} do
    {mismatches, inexact, gaussians} ->
      cond do
        op == "gaussian" and a == b -> {mismatches, inexact, gaussians + 1}
        op == "gaussian" and ulps.(a, b) <= 4 -> {mismatches, inexact + 1, gaussians + 1}
        a == b -> {mismatches, inexact, gaussians}
        true -> {[{kind, seed, op, a, b} | mismatches], inexact, gaussians}
      end
  end

if mismatches != [] do
  raise "#{length(mismatches)} values differ; first (kind, seed, op, ValiMC, vanilla): #{inspect(List.last(mismatches))}"
end

IO.puts(
  "PASS: #{length(cases)} random traces (#{length(cases) * 40} operations) equal vanilla's; " <>
    "#{gaussians - inexact} of #{gaussians} Gaussians exact, the rest within 4 ulps (Java Math.log)"
)
