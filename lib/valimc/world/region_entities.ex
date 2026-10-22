defmodule Valimc.World.RegionEntities do
  @moduledoc """
  The entity part of a region owner's state (VMC-077g): its entity store
  (`Valimc.World.Entities`, VMC-077h) and the players' transfer receipts it
  answers to, whether they are saved
  (`persistent`) and simulated (`simulate`), and the item work the owner
  schedules: the outgoing handoff, a portal arrival, automatic merges in the
  region and across owners, and ageing owed while planning.
  """

  defstruct store: nil,
            receipts: %{},
            persistent: false,
            simulate: false,
            handoff: nil,
            portal: nil,
            merge_stamp: nil,
            merge_next: nil,
            cross_next: nil,
            cross_stamp: nil,
            age_debt: 0
end
