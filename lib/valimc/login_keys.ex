defmodule Valimc.LoginKeys do
  @moduledoc "Immutable login key material, generated once at startup and read lock-free."
  alias Valimc.Protocol.Encryption

  @doc "Generate the key pair; call once at application start (cold path)."
  def init!, do: :persistent_term.put(__MODULE__, Encryption.generate_key_pair())

  def pair, do: :persistent_term.get(__MODULE__)
end
