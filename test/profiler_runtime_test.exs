defmodule Valimc.ProfilerRuntimeTest do
  use ExUnit.Case, async: false
  # Runtime configuration reads the process-wide environment.
  @runtime Path.expand("../config/runtime.exs", __DIR__)
  @variables ~w(VALIMC_PROFILER_BIND VALIMC_PROFILER_PORT VALIMC_PROFILER_URL VALIMC_PROFILER_PATH)

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)
  end

  test "an unconfigured deployment retains the local viewer defaults" do
    config = Config.Reader.read!(@runtime)[:valimc] || []

    for key <- [:profiler_ip, :profiler_port, :profiler_url],
        do: refute(Keyword.has_key?(config, key))
  end

  test "public listener and HTTPS links use one exact WebSocket origin" do
    System.put_env(%{
      "VALIMC_PROFILER_BIND" => "0.0.0.0",
      "VALIMC_PROFILER_PORT" => "8080",
      "VALIMC_PROFILER_URL" => "https://valimc.fly.dev/",
      "VALIMC_PROFILER_PATH" => "/data/profiles"
    })

    config = Config.Reader.read!(@runtime)[:valimc]
    assert config[:profiler_ip] == {0, 0, 0, 0}
    assert config[:profiler_port] == 8080
    assert config[:profiler_url] == "https://valimc.fly.dev"
    assert config[:profiler_path] == "/data/profiles"
    endpoint = config[Valimc.Net.Profiler.Endpoint]
    assert endpoint[:check_origin] == ["https://valimc.fly.dev"]
    assert endpoint[:url] == [scheme: "https", host: "valimc.fly.dev", port: 443]
  end

  test "invalid addresses, ports and public origins fail at startup" do
    for {variable, value} <- [
          {"VALIMC_PROFILER_BIND", "not-an-address"},
          {"VALIMC_PROFILER_PORT", "8080junk"},
          {"VALIMC_PROFILER_PORT", "65536"},
          {"VALIMC_PROFILER_URL", "javascript:alert(1)"},
          {"VALIMC_PROFILER_URL", "https://*.fly.dev"},
          {"VALIMC_PROFILER_URL", "https://example.com\n; script-src *"},
          {"VALIMC_PROFILER_URL", "https://user:password@example.com"},
          {"VALIMC_PROFILER_URL", "https://example.com/path"},
          {"VALIMC_PROFILER_URL", "https://example.com/?query=true"}
        ] do
      System.put_env(variable, value)
      assert_raise RuntimeError, fn -> Config.Reader.read!(@runtime) end
      System.delete_env(variable)
    end
  end
end
