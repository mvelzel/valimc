defmodule Valimc do
  @moduledoc "Elixir/OTP Minecraft Java server. See README for the implemented compatibility slice."
  def config(key), do: Application.fetch_env!(:valimc, key)
  def version, do: "26.3"
  def protocol_version, do: 777
end
