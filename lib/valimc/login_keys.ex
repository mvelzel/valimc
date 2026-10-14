defmodule Valimc.LoginKeys do
  use GenServer
  alias Valimc.Protocol.Encryption

  @moduledoc "Supervised immutable login key material; concurrent reads avoid a login coordinator."
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def pair do
    [{:pair, pair}] = :ets.lookup(__MODULE__, :pair)
    pair
  end

  @impl true
  def init(_) do
    # Startup/cold path, outside socket and simulation owners.
    pair = Encryption.generate_key_pair()
    table = :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    :ets.insert(table, {:pair, pair})
    {:ok, table}
  end
end
