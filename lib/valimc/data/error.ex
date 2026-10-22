defmodule Valimc.Data.Error do
  @moduledoc """
  One error taxonomy (VMC-077g): `{:error, {class, detail}}`, the class
  decided where the error is made, so no caller keeps a list of atoms to guess
  what an error means.

  - `:retry`: transient; the same request may succeed later unchanged (a busy
    pool or planning slot, an owner restarting or replaced, a commit whose
    outcome is uncertain, a destination's capacity).
  - `:reject`: the rules refuse it; repeating it is pointless.
  - `:conflict`: it lost a race on state; plan again from a fresh read.
  - `:invalid`: malformed input.

  Transient errors are classified everywhere they are made; the other classes
  are taken up as their modules are rewritten (see VMC-077g).
  """

  def retry(detail), do: {:error, {:retry, detail}}
  def reject(detail), do: {:error, {:reject, detail}}
  def conflict(detail), do: {:error, {:conflict, detail}}
  def invalid(detail), do: {:error, {:invalid, detail}}
end
