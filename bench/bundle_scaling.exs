# Run from the repository root: mix run bench/bundle_scaling.exs
# Measures bundling only; schema construction and warmup are outside timing.
IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}, schedulers #{System.schedulers_online()}")

measure = fn label, bundle ->
  Enum.each(1..5, fn _ -> bundle.() end)
  samples = for _ <- 1..21 do
    :erlang.garbage_collect()
    {microseconds, _} = :timer.tc(fn -> Enum.each(1..10, fn _ -> bundle.() end) end)
    microseconds / 10 / 1000
  end
  median = samples |> Enum.sort() |> Enum.at(10)
  IO.puts("#{label} median_ms=#{Float.round(median, 4)} (21 batches of 10)")
end

for depth <- [100, 200, 400] do
  schema = Enum.reduce(1..depth, %{"type" => "integer"}, fn _, child ->
    %{"properties" => %{"child" => child}}
  end)

  bundle = fn ->
    {:ok, _} = JSONSchex.bundle_fragment(schema, entry: "#")
  end

  measure.("depth=#{depth}", bundle)
end

# Repeated names are intentionally outside schema keywords, exercising fallback discovery.
for count <- [500, 1000, 2000] do
  document = %{"schema" => %{}, "x-candidates" => List.duplicate(%{"$anchor" => "same"}, count)}
  measure.("anchors=#{count}", fn ->
    {:ok, _} = JSONSchex.bundle_fragment(document, entry: "#/schema")
  end)
end

# Identical payloads and loaders except for the effective resource base.
# Unselected deep refs must still be rewritten in the redirected case.
for count <- [500, 1000, 2000], mode <- [:identity, :redirected] do
  payload = List.duplicate(%{"nested" => [%{"$ref" => "/api/value.json#value"}]}, count)
  document = %{"$ref" => "/api/value.json", "x-payload" => payload}
  base = if mode == :identity, do: "/api/value.json", else: "/mirror/value.json"
  loader = fn "/api/value.json" ->
    {:ok, %{document: %{"type" => "integer", "x-payload" => payload}, base_uri: base}}
  end
  measure.("aliases=#{mode} payload=#{count}", fn ->
    {:ok, _} = JSONSchex.bundle_fragment(document, entry: "#", base_uri: "/api/root.json", loader: loader)
  end)
end
