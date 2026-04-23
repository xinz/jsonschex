# jsonschex/bench/openapi_spec_benchmark.exs
{:ok, _} = Application.ensure_all_started(:jsv)
{:ok, _} = Application.ensure_all_started(:jsonschex)

# copy from local /opt/homebrew/Cellar/bowtie/2026.2.6/libexec/lib/python3.14/site-packages/bowtie/benchmarks/openapi_spec_schema.json
# https://github.com/bowtie-json-schema/bowtie/blob/main/bowtie/benchmarks/openapi_spec_schema.json
file_path = "./priv/openapi_spec_schema.json"
content = File.read!(file_path)
data = JSON.decode!(content)

schema = data["schema"]

test_case = Enum.find(data["tests"], fn t -> t["description"] == "Non-OAuth Scopes Example" end)
instance = test_case["instance"]

Benchee.run(
  %{
    "JSV compile" => fn ->
      JSV.build!(schema)
    end,
    "JSONSchex compile" => fn ->
      JSONSchex.compile(schema)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [{Benchee.Formatters.Console, comparison: true}]
)

jsv_schema = JSV.build!(schema)
{:ok, jx_schema} = JSONSchex.compile(schema)

Benchee.run(
  %{
    "JSV validate" => fn ->
      JSV.validate!(instance, jsv_schema)
    end,
    "JSONSchex validate" => fn ->
      JSONSchex.validate(jx_schema, instance)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [{Benchee.Formatters.Console, comparison: true}]
)
