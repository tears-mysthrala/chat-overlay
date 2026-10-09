# Build-only compatibility patch for the pinned Hex source; Refs #70.
path = Path.join(["deps", "postgrex", "mix.exs"])
source = File.read!(path)
original_hash = "63d6f2696a3df8677167f571bbd74da7fb93bc995c17a4aa0f31e16782d5720c"
digest = fn bytes -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) end

replacement =
  String.replace(
    source,
    "xref: [exclude: [Jason]]",
    "elixirc_options: [no_warn_undefined: [Jason]]"
  )

if digest.(source) != original_hash do
  raise "Postgrex build metadata differs from reviewed 0.22.4 source"
end

if replacement == source do
  raise "Postgrex compatibility patch did not match"
end

File.write!(path, replacement)
IO.puts("Postgrex build metadata compatibility patch applied; runtime source unchanged")
