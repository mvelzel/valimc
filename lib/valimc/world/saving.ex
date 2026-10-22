defmodule Valimc.World.Saving do
  @moduledoc """
  The autosave switch (VMC-010b), vanilla's per-level `noSave` that
  `/save-off` and `/save-on` change: region owners skip their periodic save of
  changed cells and scheduled ticks while it is off. Player saves, the world
  clock and the log's frames continue, as do saves at unload
  and shutdown; the switch resets to on at startup, as in vanilla.

  A flag in `:persistent_term`, set at application start; region owners read it.
  """
  @key {__MODULE__, :auto}

  @doc "Autosave on, at application start."
  def init!, do: :persistent_term.put(@key, true)

  def auto?, do: :persistent_term.get(@key, true)

  @doc "Sets autosave; `:unchanged` when it already was."
  def set_auto(on) when is_boolean(on) do
    if auto?() == on do
      :unchanged
    else
      :persistent_term.put(@key, on)
      :ok
    end
  end
end
