defmodule Valimc.World.RegionEntities do
  @moduledoc """
  The entity part of a region owner's state (VMC-077g): its item entities
  and the players' transfer receipts they answer to, whether they are saved
  (`persistent`) and simulated (`simulate`), and the item work the owner
  schedules: the outgoing handoff, a portal arrival, automatic merges in the
  region and across owners, and ageing owed while planning. The entity store
  (VMC-077h) replaces it.
  """

  defstruct items: nil,
            receipts: %{},
            persistent: false,
            simulate: false,
            handoff: nil,
            portal: nil,
            merge_stamp: nil,
            merge_next: nil,
            cross_next: nil,
            cross_stamp: nil,
            cross_scan_stamp: nil,
            cross_cursor: nil,
            cross_retry: false,
            age_debt: 0
end
