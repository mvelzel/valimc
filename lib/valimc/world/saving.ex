defmodule Valimc.World.Saving do
  @moduledoc """
  The autosave switch (VMC-010b), vanilla's per-level `noSave` that
  `/save-off` and `/save-on` change: region owners skip their periodic save of
  changed cells and scheduled ticks while it is off. Player saves, the world
  clock, transfers and other journaled writes continue, as do saves at unload
  and shutdown; the switch resets to on at startup, as in vanilla.

  The owner serialises changes; region owners read the published flag.
  """
  use GenServer

  @key {__MODULE__, :auto}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def auto?, do: :persistent_term.get(@key, true)

  @doc "Sets autosave; `:unchanged` when it already was."
  def set_auto(on) when is_boolean(on), do: GenServer.call(__MODULE__, {:auto, on})

  @impl true
  def init(_opts) do
    :persistent_term.put(@key, true)
    {:ok, true}
  end

  @impl true
  def handle_call({:auto, on}, _from, on), do: {:reply, :unchanged, on}

  def handle_call({:auto, on}, _from, _previous) do
    :persistent_term.put(@key, on)
    {:reply, :ok, on}
  end
end
