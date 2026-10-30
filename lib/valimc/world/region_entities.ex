defmodule Valimc.World.RegionEntities do
  @moduledoc """
  The entity part of a region owner's state (VMC-077g): its entity store
  (`Valimc.Entity.Store`, VMC-077h), its replication state
  (`Valimc.Entity.Tracking`), whether they are saved (`persistent`) and
  simulated (`simulate`), and the item work the owner
  schedules: the outgoing handoff, a portal arrival, automatic merges in the
  region and across owners, and ageing owed while planning, and players'
  drops waiting for a plan to finish (VMC-077i3).
  """

  defstruct store: nil,
            tracking: %Valimc.Entity.Tracking{},
            persistent: false,
            simulate: false,
            handoff: nil,
            portal: nil,
            merge_stamp: nil,
            merge_next: nil,
            cross_next: nil,
            cross_stamp: nil,
            age_debt: %{},
            dropped: []
end
