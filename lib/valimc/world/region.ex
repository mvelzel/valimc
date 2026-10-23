defmodule Valimc.World.Region do
  alias Valimc.Data.Grid
  use GenServer

  @moduledoc """
  A group process (VMC-077j): the owner of a connected set of 8 × 8 sections
  of one dimension, each a `Valimc.World.RegionData` with its own blocks,
  entities, log stream and published table. The section stays the unit of
  storage, generation and light; the group is the unit of ownership, time and
  durability:

  - **Routing.** Callers hold `{pid, epoch}` per section (`World.owner/1`,
    the Directory's row). A call or message names its section by that epoch,
    by a chunk or position of it, or by key, and the group runs it on that
    section's state.
  - **Time.** One tick runs every section, in key order, with one tick number
    (`Valimc.World.GameTick`, the world clock's game time), so groups that
    merge need no offsets.
  - **Locality.** Block rules run across the group's sections (each section
    hands its siblings' stores to the engine) and stop only at the group's
    edge; a run's changes in a sibling apply before the group's next cut.
  - **Durability.** The group cuts every section's changes at once and sends
    them as one record of the write-ahead log (`Log.commit_group/4`): a
    change that spans sections is durable whole or not at all.
  - **Transfer.** One protocol moves sections and players (VMC-077y, see
    `transfer/4`): adopt once every frame sent is durable, held, release.
    A section keeps its epoch; its store, table and route go to the target.
  - **Strays.** What names a section the group does not hold goes on by the
    Directory's route (`elsewhere/3`); only the regionizer retires groups.

  A section is admitted into a group of its own; the regionizer merges and
  splits groups. A group that crashes takes its sections down; each is
  admitted again from its log.
  """
  alias Valimc.Native

  alias Valimc.World.{
    BlockBatch,
    GameTick,
    RegionData,
    RegionStorage,
    Spawning,
    TickClock,
    TickPipeline
  }

  alias Valimc.Storage.Log
  alias Valimc.Player.Host

  # The commit timer cuts every section once in this many (`handle_info(:commit, _)`).
  @sweep_commits 20

  # A group starts with its first section, by key `{dimension, sx, sz}`, or empty.
  def start_link({:empty, dimension}),
    do: GenServer.start_link(__MODULE__, {:empty, dimension})

  def start_link({{_, _, _} = section, token}),
    do:
      GenServer.start_link(__MODULE__, {section, token},
        name: {:via, Registry, {Valimc.RegionRegistry, section}}
      )

  def child_spec({section, token}),
    do: %{
      id: {__MODULE__, section},
      start: {__MODULE__, :start_link, [{section, token}]},
      restart: :temporary,
      shutdown: 20_000
    }

  @doc """
  Hand `keys` (all of `source`'s sections by default) to the group `target`,
  with the players standing in them, at `source`'s next tick boundary once
  their frames are durable: `{:ok, moved}`, the keys it still held and
  handed over (one it no longer holds unloaded after it was named), or
  `{:error, reason}`. Only the regionizer moves sections.
  """
  def hand_over(source, target, keys \\ :all) when is_pid(source) and is_pid(target),
    do: GenServer.call(source, {:hand_over, target, keys}, 30_000)

  @doc """
  Move `keys` (`{sx, sz}`) of group `pid` of `dimension` into a new group:
  `{:ok, new_pid, moved}`, or `{:ok, nil, []}` when `pid` holds none of them
  any more (the new group then stops at once).
  """
  def split(pid, dimension, keys) when is_pid(pid) and is_list(keys) do
    with {:ok, target} <-
           DynamicSupervisor.start_child(
             Valimc.RegionSupervisor,
             %{
               id: make_ref(),
               start: {__MODULE__, :start_link, [{:empty, dimension}]},
               restart: :temporary,
               shutdown: 20_000
             }
           ) do
      case safe_hand_over(pid, target, keys) do
        {:ok, [_ | _] = moved} ->
          {:ok, target, moved}

        other ->
          DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, target)
          with {:ok, []} <- other, do: {:ok, nil, []}
      end
    end
  end

  defp safe_hand_over(source, target, keys) do
    hand_over(source, target, keys)
  catch
    :exit, reason -> {:error, {:hand_over, reason}}
  end

  @doc """
  A call to a group. Inside one of this group's session callbacks
  (`Valimc.Player.Host`) a call to the group itself runs inline, as a plain
  call inside the owner.
  """
  def call(pid, message, timeout) when pid == self() do
    case Valimc.Player.Host.inline(&inline_call(&1, message)) do
      {:ok, reply} -> reply
      :none -> GenServer.call(pid, message, timeout)
    end
  end

  # A group that stopped before it read the call (it retired after its
  # sections moved) never ran it: it goes to the route of the epoch it names.
  def call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {reason, _} = exit when reason in [:noproc, :normal] ->
      epoch = if is_tuple(message) and tuple_size(message) >= 2, do: elem(message, 1)

      case Valimc.World.Directory.epoch_owner(epoch) do
        owner when is_pid(owner) and owner != pid -> GenServer.call(owner, message, timeout)
        _ -> exit(exit)
      end
  end

  @doc "The keys of the sections group `pid` owns."
  def sections(pid), do: call(pid, :sections, 5000)

  def flush(pid), do: call(pid, :flush, budget(pid, 15_000))

  @doc """
  The calling process holds a `type` ticket (`Valimc.World.Tickets`) over
  `chunks` of section `key`; an empty list withdraws it. Asynchronous; a
  later call of the same type replaces it.
  """
  def ticket({pid, _epoch}, key, type, chunks), do: ticket(pid, key, type, chunks)

  def ticket(pid, key, type, chunks) when is_pid(pid) do
    send(pid, {:ticket, key, self(), type, chunks})
    :ok
  end

  @doc """
  Several tickets of the caller for sections of the group `pid`, as one
  message: `[{key, type, chunks}]` (a view's tickets per group).
  """
  def tickets(pid, entries) when is_pid(pid) and is_list(entries) do
    send(pid, {:tickets, self(), entries})
    :ok
  end

  # Owner call budgets (and the deadlines requests carry) scale with
  # `owner_call_scale`: 1 in play; tests on a loaded host raise it, and pin it back to
  # 1 for an owner whose timeout they exercise (VMC-073).
  defp budget(pid, ms), do: ms * Valimc.config(:owner_call_scale, pid)

  @doc """
  `:ok` once `chunks` of the owner's region are generated (VMC-075), waiting at
  most `timeout` ms; `{:error, reason}` otherwise.
  """
  def await_chunks({pid, _epoch}, chunks, timeout) do
    call(pid, {:await_chunks, chunks}, max(timeout, 0))
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:chunk_generating)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc "Run `ticks` region ticks now, in order (deterministic tests; `:manual` owners)."
  def step({pid, _epoch}, ticks \\ 1),
    do: call(pid, {:step, ticks}, budget(pid, 10_000))

  @doc """
  The live preserved block entity at `position` (`%{type: id, nbt: binary}`,
  an end gateway's exit for one, VMC-026b4), or nil.
  """
  def block_entity({pid, epoch}, position) when is_pid(pid) and is_reference(epoch) do
    call(pid, {:block_entity, epoch, position}, 1000)
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_query_timeout)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc """
  Add or replace preserved block entities (`position => {type_id, nbt}`, each
  of the type its block creates); they join the owner's next frame.
  """
  def put_block_entities({pid, epoch}, entries)
      when is_pid(pid) and is_reference(epoch) and is_map(entries) do
    call(pid, {:put_block_entities, epoch, entries}, 7000)
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_entity_commit_uncertain)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc "Read one owner-local block revision; this observation does not authorize later mutations."
  def observe_blocks(owner, positions, expected_revision \\ :any)

  def observe_blocks({pid, epoch}, positions, expected_revision)
      when is_pid(pid) and is_reference(epoch) do
    if RegionData.valid_block_query?(positions, expected_revision) do
      call(
        pid,
        {:observe_blocks, epoch, positions, expected_revision},
        budget(pid, 250)
      )
    else
      {:error, :invalid_block_query}
    end
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_query_timeout)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  def observe_blocks(_, _, _), do: {:error, :invalid_block_query}

  @doc "A chunk's current light image (VMC-022c), for diagnostics and tests."
  def light_image({pid, epoch}, chunk) when is_pid(pid) and is_reference(epoch),
    do: call(pid, {:light_image, epoch, chunk}, budget(pid, 1000))

  @doc "`/fillbiome` in this region's `chunks` (VMC-053j4): `{:ok, changed_cells}`."
  def fill_biomes({pid, epoch}, chunks, box, biome, filter)
      when is_pid(pid) and is_reference(epoch) do
    call(pid, {:fill_biomes, epoch, chunks, box, biome, filter}, budget(pid, 2000))
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:biome_fill_timeout)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc "Column images of this region's `chunks` for `/place` (VMC-053)."
  def column_images({pid, epoch}, chunks) when is_pid(pid) and is_reference(epoch) do
    call(pid, {:column_images, epoch, chunks}, budget(pid, 2000))
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:column_query_timeout)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc "Retire only the specified connection's current view in this owner incarnation."
  def unsubscribe_container({pid, epoch}, connection, ref)
      when is_pid(pid) and is_reference(epoch) and is_pid(connection) and is_reference(ref) do
    send(pid, {:resource, epoch, {:container_unsubscribe, connection, ref}})
    :ok
  end

  @doc "The states of a box of this region, x fastest (`Valimc.World.BoxEdit`)."
  def read_box({pid, epoch}, min, max) when is_pid(pid) and is_reference(epoch) do
    call(pid, {:read_box, epoch, min, max}, budget(pid, 1000))
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_query_timeout)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc "Check and lock a box edit's part in this owner (`Valimc.World.BoxEdit`)."
  def prepare_box({pid, epoch}, token, edits, expected, entries, entities \\ [])
      when is_pid(pid) do
    call(
      pid,
      {:prepare_box, epoch, token, edits, expected, entries, entities},
      budget(pid, 2000)
    )
  catch
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc "Commit a prepared box edit part (`:retry` while a write is in flight)."
  def commit_box({pid, epoch}, token, entries) when is_pid(pid) do
    call(pid, {:commit_box, epoch, token, entries}, budget(pid, 7000))
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_commit_uncertain)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc "Release a prepared box edit part."
  def abort_box({pid, epoch}, token) when is_pid(pid) do
    call(pid, {:abort_box, epoch, token}, budget(pid, 1000))
  catch
    :exit, _ -> :ok
  end

  @doc """
  Commit a prepared owner-local block batch if the observation it was planned on
  (`revision`: an observation's section `fence`, or its region revision) is still
  current. Returns the new region revision. No cross-owner atomicity.
  """
  def set_blocks({pid, epoch}, revision, edits)
      when is_pid(pid) and is_reference(epoch) and (is_map(revision) or is_integer(revision)) do
    with {:ok, batch} <- BlockBatch.prepare(edits),
         do: call(pid, {:set_blocks, epoch, revision, batch}, budget(pid, 1000))
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_commit_uncertain)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  def set_blocks(_, _, _), do: {:error, :invalid_block_batch}

  @doc """
  `set_blocks/3` whose block entity blocks at `entity_positions` may be types
  ValiMC does not model: the caller writes their records next
  (`put_block_entities/2`), as `/place` does (VMC-053).
  """
  def set_blocks({pid, epoch}, revision, edits, entity_positions)
      when is_pid(pid) and is_reference(epoch) and is_struct(entity_positions, MapSet) do
    with {:ok, batch} <- BlockBatch.prepare(edits),
         do:
           call(
             pid,
             {:set_blocks, epoch, revision, batch, entity_positions},
             budget(pid, 1000)
           )
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_commit_uncertain)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc """
  What placing `item` at `position` writes (VMC-029d), the click's inputs
  `values` (`Valimc.Blocks.Placement.target/3`): `{:ok, [{position, state}]}`
  or `{:error, :refused}` when vanilla places nothing.
  """
  def placement({pid, epoch}, item, values, position)
      when is_pid(pid) and is_reference(epoch) and is_integer(item) and is_list(values) do
    call(pid, {:placement, epoch, item, values, position}, budget(pid, 1000))
  catch
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc "Internal creative placement commit; caller must freshly admit its player and held item."
  def place_block({pid, epoch}, revision, %BlockBatch{} = batch, deadline)
      when is_pid(pid) and is_reference(epoch) and (is_map(revision) or is_integer(revision)) and
             is_integer(deadline) do
    call(pid, {:place_block, epoch, revision, batch, deadline}, budget(pid, 1000))
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_commit_uncertain)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  def place_block(_, _, _, _), do: {:error, :invalid_placement}

  @doc """
  A player's bucket in the owner of `action`'s cell (VMC-031a), run by the
  block rules: `{:empty, position, fluid, retry, secondary}` (`BucketItem.
  emptyContents`) or `{:pickup, position}` (`BucketPickup.pickupBlock`).
  `{:ok, result}`: for a bucket emptied 0 (it could not), 1 (placed) or 2
  (evaporated); for a pickup 0 (nothing) or the item's index + 1
  (`Valimc.Blocks.Fluids.pickup_item/1`).
  """
  def bucket({pid, epoch}, action) when is_pid(pid) and is_reference(epoch) do
    call(pid, {:bucket, epoch, action}, budget(pid, 1000))
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_commit_uncertain)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc "One fresh creative destruction through the owner, including its owned metadata journal."
  def destroy_block({pid, epoch}, revision, position, deadline) do
    call(pid, {:destroy_block, epoch, revision, position, deadline}, budget(pid, 1000))
  catch
    :exit, {:timeout, _} -> Valimc.Data.Error.retry(:block_commit_uncertain)
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  @doc """
  The `block_entity_data` packet of a live imported block entity at `position`
  (`{:ok, packet | nil}`): a refused change resends it after the block, since
  the client dropped the block entity when it predicted the change (VMC-021e1).
  """
  def block_entity_update({pid, epoch}, position) do
    call(pid, {:block_entity_update, epoch, position}, budget(pid, 250))
  catch
    :exit, _ -> {:ok, nil}
  end

  @doc "Send current clicked/adjacent corrections from the same sender as owner block publications."
  def correct_blocks({pid, epoch}, positions, connection) when is_pid(connection) do
    call(pid, {:correct_blocks, epoch, positions, connection}, budget(pid, 250))
  catch
    :exit, _ -> Valimc.Data.Error.retry(:region_unavailable)
  end

  # Scene-only API: these operations never consume a player inventory.
  def create_item({pid, epoch}, stack, position),
    do: call(pid, {:create_item, epoch, stack, position}, budget(pid, 6000))

  def replace_item({pid, epoch, id, revision}, stack),
    do: call(pid, {:replace_item, epoch, id, revision, stack}, budget(pid, 6000))

  def remove_item({pid, epoch, id, revision}),
    do: call(pid, {:remove_item, epoch, id, revision}, budget(pid, 6000))

  @doc """
  A block menu's grant for the player whose connection is `viewer`
  (VMC-077i3, `Valimc.Menus.MenuAccess`): the decision, at once.
  """
  def menu({pid, epoch}, viewer, position, grant),
    do: call(pid, {:menu, epoch, viewer, position, grant}, budget(pid, 1000))

  @doc """
  A click in the container menu at `position` that `viewer`'s view `ref`
  shows (`Valimc.World.ContainerClicks`): `{:ok, inventory, entry, learned}`.
  """
  def container_click({pid, epoch}, viewer, ref, position, actor, click),
    do:
      call(pid, {:container_click, epoch, viewer, ref, position, actor, click}, budget(pid, 1000))

  @doc """
  A survival break of the block at `position` (VMC-029e): `writes` maps each
  cell it changes to `{expected, new}` (the broken cell first among them),
  and `records` are its drops and experience orbs.
  """
  def mine_block({pid, epoch}, position, writes, records) when is_map_key(writes, position),
    do: call(pid, {:mine_block, epoch, position, writes, records}, budget(pid, 1000))

  @doc """
  A player's drop (VMC-077i3): the section adopts the entity `records`, after
  a running item plan if one runs.
  """
  def drop_items({pid, epoch}, records),
    do: call(pid, {:drop_items, epoch, records}, budget(pid, 1000))

  @doc """
  A player's pickup: what fits `inventory` of the item `uuid` the player
  (`actor`) touches. `{:ok, inventory, taken}` or `{:error, reason}`.
  """
  def take_item({pid, epoch}, actor, uuid, inventory),
    do: call(pid, {:take_item, epoch, actor, uuid, inventory}, budget(pid, 1000))

  @doc """
  A player's (`actor`) pickup of the stuck arrow `uuid` it touches (VMC-037o):
  `{:ok, inventory}` with it added, or `{:error, reason}`.
  """
  def take_arrow({pid, epoch}, actor, uuid, inventory),
    do: call(pid, {:take_arrow, epoch, actor, uuid, inventory}, budget(pid, 1000))

  @doc """
  `Projectile.deflect(AIM_DEFLECT)` of projectile `uuid` by a player's attack
  (VMC-037o): it flies along `look`, owned by `owner`. `:ok` or `{:error, reason}`.
  """
  def deflect_projectile({pid, epoch}, uuid, look, owner),
    do: call(pid, {:deflect_projectile, epoch, uuid, look, owner}, budget(pid, 1000))

  @doc "A player's XP pickup: one unit of the orb `uuid` of `value` it touches."
  def take_orb({pid, epoch}, actor, uuid, value),
    do: call(pid, {:take_orb, epoch, actor, uuid, value}, budget(pid, 1000))

  @doc """
  A hit on body `uuid` of a section (VMC-037n): `{:ok, outcome}` (see
  `RegionData.hurt_entity/3`) or `{:error, reason}`.
  """
  def hurt_entity({pid, epoch}, uuid, hit),
    do: call(pid, {:hurt_entity, epoch, uuid, hit}, budget(pid, 1000))

  @doc "A name tag's `name` (a text component) on the mob `uuid`: `:ok` (VMC-042a)."
  def name_entity({pid, epoch}, uuid, name),
    do: call(pid, {:name_entity, epoch, uuid, name}, budget(pid, 1000))

  @doc "`/kill` of the entities `uuids` of a section: `{:ok, killed}` (VMC-043a)."
  def kill_entities({pid, epoch}, uuids),
    do: call(pid, {:kill_entities, epoch, uuids}, budget(pid, 1000))

  @doc """
  A teleport of the entity `uuid` of a section to `position`, facing
  `rotation` (`{yaw, pitch}`) or as it faced (nil): `:ok` once it moved or its
  handoff left (VMC-043a).
  """
  def move_entity({pid, epoch}, uuid, position, rotation),
    do: call(pid, {:move_entity, epoch, uuid, position, rotation}, budget(pid, 1000))

  @doc "Trusted same-owner pairs; reply follows one durable replacement/removal commit."
  def merge_items({pid, epoch}, pairs),
    do:
      call(
        pid,
        {:merge_items, epoch, pairs, System.monotonic_time(:millisecond) + budget(pid, 250)},
        budget(pid, 6000)
      )

  @doc "Trusted accepted steps; caller must supply fresh geometry and retain the returned fences."
  def advance_items({pid, epoch}, steps),
    do:
      call(
        pid,
        {:advance_items, epoch, steps, System.monotonic_time(:millisecond) + budget(pid, 250)},
        budget(pid, 6000)
      )

  @doc "Trusted accepted ordinary motion; coalesced persistence may roll back motion after a crash."
  def publish_item_motion({pid, epoch}, steps),
    do:
      call(
        pid,
        {:publish_item_motion, epoch, steps,
         System.monotonic_time(:millisecond) + budget(pid, 250)},
        budget(pid, 2000)
      )

  def find_item({pid, epoch}, uuid),
    do: call(pid, {:find_item, epoch, uuid}, budget(pid, 5000))

  @doc "Trusted accepted border steps; success means durable withdrawal, with asynchronous delivery."
  def handoff_items({pid, epoch}, destination, steps),
    do:
      call(
        pid,
        {:handoff_items, epoch, destination, steps,
         System.monotonic_time(:millisecond) + budget(pid, 250)},
        budget(pid, 6000)
      )

  @doc "Internal entity handoff inbox; delivery must follow a durably committed source intent."
  def apply_entity_handoff({pid, epoch}, transfer),
    do: call(pid, {:entity_handoff, epoch, transfer}, budget(pid, 6000))

  ## Group

  @impl true
  def init({:empty, dimension}) do
    Process.flag(:trap_exit, true)
    Valimc.World.Dimension.put(dimension)
    {:ok, new_state(dimension, nil)}
  end

  def init({{dimension, sx, sz}, token}) do
    Process.flag(:trap_exit, true)
    # The group, and everything it routes, works in its sections' dimension.
    Valimc.World.Dimension.put(dimension)
    key = {sx, sz}
    {:ok, new_state(dimension, key), {:continue, {:load, key, token}}}
  end

  defp new_state(dimension, anchor) do
    %{
      dimension: dimension,
      sections: %{},
      epochs: %{},
      owners: %{},
      # What the block rules of one section read of the others: key =>
      # %{blocks, absent, busy} (VMC-077j).
      peers: %{},
      # Transfers sent, not yet held: ref => %{target, monitor, players}.
      transfers: %{},
      # Transfers waiting until every frame sent is durable (`send_ready/1`).
      outgoing: [],
      retiring: false,
      # Calls for sections elsewhere, relayed (`elsewhere/3`): request => caller.
      relays: :gen_server.reqids_new(),
      # A full collection is due once the sections handed in are adopted.
      collect: false,
      # The key whose log stripe the group commits to.
      route: anchor && {:region, dimension, anchor},
      stripe: nil,
      # Sections changed since the last cut (`commit_frames/2`).
      touched: MapSet.new(),
      tick_clock: nil,
      # `:manual` groups (tests) tick only through `step/2`, numbered on their own.
      manual: false,
      tick_timer: nil,
      tick_steps: nil,
      commit_timer: nil,
      commit_ms: RegionStorage.commit_ms(),
      commits: 0,
      # Players this group hosts (`Valimc.Player.Host`): uuid => entry.
      players: %{},
      # Players that left, until their file holds their last frame: uuid => storage.
      player_leaving: %{},
      # Natural spawning's randoms (VMC-042a), nil where it is off.
      spawning: if(Spawning.enabled?(anchor), do: Spawning.new())
    }
  end

  # The routing key of this group's section `{sx, sz}`.
  defp section(state, {sx, sz}), do: {state.dimension, sx, sz}

  @impl true
  def handle_continue({:load, key, token}, state) do
    started = System.monotonic_time(:microsecond)
    resource = state.dimension |> RegionData.load(key) |> Valimc.World.LightHalo.hello()
    Valimc.Data.Metrics.add(:region_loads)

    Valimc.Data.Metrics.add(
      :region_load_microseconds,
      System.monotonic_time(:microsecond) - started
    )

    case Valimc.World.Directory.publish(section(state, key), token, %{
           publication: resource.publication,
           epoch: resource.epoch
         }) do
      :ok ->
        if Valimc.config(:regionizer, key),
          do: Valimc.World.Regionizer.loaded(state.dimension, key, self())

        {:noreply, state |> put_section(key, token, resource) |> start_clock()}

      {:error, reason} ->
        {:stop, reason, put_section(state, key, token, resource)}
    end
  end

  defp put_section(state, key, token, resource) do
    resource = %{
      resource
      | storage: %{resource.storage | route: state.route || resource.storage.owner}
    }

    %{
      state
      | sections: Map.put(state.sections, key, %{resource: resource, admission: token}),
        peers: peer(state.peers, key, resource),
        touched: MapSet.put(state.touched, key),
        epochs: Map.put(state.epochs, resource.epoch, key),
        owners: Map.put(state.owners, resource.storage.owner, key),
        route: state.route || resource.storage.owner
    }
  end

  defp drop_section(state, key) do
    {%{resource: resource}, sections} = Map.pop(state.sections, key)

    %{
      state
      | sections: sections,
        peers: Map.delete(state.peers, key),
        epochs: Map.delete(state.epochs, resource.epoch),
        owners: Map.delete(state.owners, resource.storage.owner)
    }
  end

  # The group's tick and commit timers start with its first section; its
  # sections continue at the group's tick.
  defp start_clock(%{tick_clock: nil} = state) do
    key = state.sections |> Map.keys() |> Enum.min()
    now = System.monotonic_time(:millisecond)
    manual = Valimc.config(:region_ticks, key) != :timer
    tick = state.sections[key].resource.game_tick
    tick = if manual, do: tick, else: max(GameTick.current(), tick)
    clock = %{TickClock.new(make_ref(), now) | tick: tick}
    timer = if not manual, do: Process.send_after(self(), {:tick, clock.token}, 50)
    commit_ms = Valimc.config(:region_commit_ms, key)
    commit = Process.send_after(self(), :commit, commit_ms)

    %{
      state
      | tick_clock: clock,
        manual: manual,
        tick_timer: timer,
        commit_timer: commit,
        commit_ms: commit_ms
    }
    |> rebase(key)
  end

  defp start_clock(state), do: state

  defp rebase(state, key),
    do:
      put_resource(
        state,
        key,
        RegionData.rebase(state.sections[key].resource, state.tick_clock.tick)
      )

  # A section handed in continues at the group's tick, or the group at the
  # section's when that is later: numbers never go back for a section (its
  # entity frames and scheduled ticks are numbered by them).
  defp catch_up(state, key) do
    tick = state.sections[key].resource.game_tick

    if tick > state.tick_clock.tick do
      state = %{state | tick_clock: %{state.tick_clock | tick: tick}}
      Enum.reduce(Map.keys(state.sections), state, &rebase(&2, &1))
    else
      rebase(state, key)
    end
  end

  # The next tick's number: the world's game tick, never behind the group's.
  defp next_tick(%{manual: true, tick_clock: clock}), do: clock.tick + 1
  defp next_tick(%{tick_clock: clock}), do: max(clock.tick + 1, GameTick.current())

  ## Calls

  @impl true
  def handle_call({:owner, key}, from, state) do
    case state.sections do
      %{^key => %{resource: resource}} -> {:reply, {:ok, {self(), resource.epoch}}, state}
      _ -> elsewhere(state, {:key, key}, {:call, from, {:owner, key}})
    end
  end

  # A connection's player enters play here (`Valimc.Player.Host`).
  def handle_call({:host_player, session}, _from, state),
    do: {:reply, :ok, Host.host(state, session)}

  def handle_call({:player_call, uuid, message}, from, state),
    do: {:noreply, Host.call(state, uuid, message, from)}

  def handle_call({:player_left, uuid, reason}, from, state),
    do: {:noreply, Host.left(state, uuid, reason, from)}

  def handle_call(:sections, _from, state),
    do: {:reply, state.sections |> Map.keys() |> Enum.sort(), state}

  # Deterministic stepping: run `ticks` group ticks now, in order.
  def handle_call({:step, ticks}, _from, state) when is_integer(ticks) and ticks in 1..1200 do
    state =
      Enum.reduce(1..ticks, state, fn _, acc ->
        clock = %{acc.tick_clock | tick: next_tick(acc)}
        run_tick(%{acc | tick_clock: clock}, clock.tick, System.monotonic_time(:millisecond))
      end)

    {:reply, {:ok, state.tick_clock.tick}, commit_frames(state)}
  end

  def handle_call(:flush, _from, state) do
    state = commit_frames(state, true)

    {state, reply} =
      Enum.reduce(Map.keys(state.sections), {state, :ok}, fn key, {acc, reply} ->
        case section_call(acc, key, :flush, nil) do
          {:reply, acc, :ok} -> {acc, reply}
          {:reply, acc, other} -> {acc, other}
          {_, acc, _} -> {acc, reply}
        end
      end)

    {:reply, reply, state}
  end

  # The reply waits until the sections' frames are durable (`send_ready/1`).
  def handle_call({:hand_over, target, keys}, from, state) do
    if target == self() or not Process.alive?(target),
      do: {:reply, {:error, :invalid_handoff}, state},
      else: {:noreply, state |> commit_frames(true) |> queue({:sections, from, target, keys})}
  end

  def handle_call(message, from, state) do
    case target(message, state) do
      {:section, key} -> section_result(section_call(state, key, message, from), from)
      other -> elsewhere(state, other, {:call, from, message})
    end
  end

  # The section a message names: by epoch (most), by chunk, or by key.
  defp target({:chunk, chunk}, state), do: by_key(state, Grid.region_key(chunk))

  defp target({:await_chunks, [chunk | _]}, state),
    do: by_key(state, Grid.region_key(chunk))

  defp target(message, state) when is_tuple(message) and tuple_size(message) >= 2 do
    epoch = elem(message, 1)

    case state.epochs do
      %{^epoch => key} -> {:section, key}
      _ -> {:epoch, epoch}
    end
  end

  defp target(_message, _state), do: :none

  defp by_key(state, key) do
    if Map.has_key?(state.sections, key), do: {:section, key}, else: {:key, key}
  end

  defp section_call(state, key, message, from) do
    {kind, resource, rest} =
      split_result(RegionData.handle_call(message, from, enter(state, key)))

    {kind, state |> put_resource(key, resource) |> deliver_rules(key), rest}
  end

  defp split_result({:reply, reply, resource}), do: {:reply, resource, reply}
  defp split_result({:noreply, resource}), do: {:noreply, resource, nil}
  defp split_result({:stop, reason, resource}), do: {:stop, resource, reason}

  defp put_resource(state, key, resource) do
    {section, sections} =
      Map.get_and_update!(state.sections, key, &{&1, %{&1 | resource: resource}})

    %{
      state
      | sections: sections,
        peers: peer(state.peers, key, resource),
        touched: touch(state.touched, key, section.resource, resource)
    }
  end

  # A section whose storage and stored parts are what they were has nothing
  # for the next cut (VMC-077w): a tick that changed nothing touches nothing.
  defp touch(touched, key, old, new) do
    if old.storage === new.storage and old.scheduled_ticks === new.scheduled_ticks and
         old.entities.store === new.entities.store and old.containers === new.containers and
         old.block_entities === new.block_entities,
       do: touched,
       else: MapSet.put(touched, key)
  end

  # A section's state as its code runs: with what it reads of its siblings.
  defp enter(state, key), do: %{state.sections[key].resource | siblings: state.peers}

  defp peer(peers, key, resource) do
    absent = resource.generation.absent
    busy = RegionData.write_busy(resource) != nil

    case peers do
      %{^key => %{absent_set: ^absent, busy: ^busy}} ->
        peers

      _ ->
        Map.put(peers, key, %{
          blocks: resource.blocks,
          absent_set: absent,
          absent: MapSet.to_list(absent),
          busy: busy
        })
    end
  end

  # What a section's call did to its siblings (block-rule changes, entities
  # moved, a donor to merge) applies before the group's next cut, so it
  # commits with the call's own changes; what that sends back applies too.
  defp deliver_rules(state, key) do
    case state.sections do
      %{^key => %{resource: %{sibling_effects: [_ | _] = effects} = resource}} ->
        state = put_resource(state, key, %{resource | sibling_effects: []})

        Enum.reduce(effects, state, fn {sibling, effect}, acc ->
          cond do
            sibling == :players ->
              deliver_players(acc, effect)

            Map.has_key?(acc.sections, sibling) ->
              acc
              |> put_resource(sibling, RegionData.apply_sibling(enter(acc, sibling), effect))
              |> deliver_rules(sibling)

            true ->
              acc
          end
        end)

      _ ->
        state
    end
  end

  # A section's call that concerns the group's players (VMC-050a): an
  # explosion goes to each hosted player of its dimension within 64 blocks,
  # whose session takes its hit and packet (`Valimc.Player.Explosions`); a
  # landing anvil to each of its dimension, whose session checks its box.
  defp deliver_players(state, {:falling_block, _box, _amount} = message) do
    Enum.reduce(state.players, state, fn {uuid, %{session: %{player: player}}}, acc ->
      if player.dimension == state.dimension, do: Host.info(acc, uuid, message), else: acc
    end)
  end

  defp deliver_players(state, {:explosion, %{center: {cx, cy, cz}}, _} = message) do
    Enum.reduce(state.players, state, fn {uuid, %{session: %{player: player}}}, acc ->
      dx = player.x - cx
      dy = player.y - cy
      dz = player.z - cz

      if player.dimension == state.dimension and dx * dx + dy * dy + dz * dz < 4096.0,
        do: Host.info(acc, uuid, message),
        else: acc
    end)
  end

  defp section_result({:reply, state, reply}, _from), do: {:reply, reply, commit_frames(state)}
  defp section_result({:noreply, state, _}, _from), do: {:noreply, commit_frames(state)}
  defp section_result({:stop, state, reason}, _from), do: {:stop, reason, state}

  # A session's call to its own group (`call/3`): it runs as the group would
  # run it. A reply the group sends itself at once is taken from the mailbox;
  # one that waits for durability cannot be made inline.
  defp inline_call(state, {:owner, key}) do
    case state.sections do
      %{^key => %{resource: resource}} -> {{:ok, {self(), resource.epoch}}, state}
      _ -> {Valimc.Data.Error.retry(:stale_owner), state}
    end
  end

  defp inline_call(state, message) do
    dimension = Valimc.World.Dimension.put(state.dimension)

    try do
      case target(message, state) do
        {:section, key} ->
          tag = make_ref()

          case section_call(state, key, message, {self(), tag}) do
            {:reply, state, reply} ->
              {reply, commit_frames(state)}

            {:noreply, state, _} ->
              receive do
                {^tag, reply} -> {reply, commit_frames(state)}
              after
                0 -> raise ArgumentError, "inline owner call waits: #{inspect(elem(message, 0))}"
              end
          end

        _ ->
          {Valimc.Data.Error.retry(:stale_owner), state}
      end
    after
      Valimc.World.Dimension.put(dimension)
    end
  end

  # A message for a section this group does not hold goes on by the
  # Directory's current route; one that has none is answered as for a stale
  # owner. A call is relayed, so this group, which its caller watches, stays
  # until the answer passed through (`relayed/2`).
  defp elsewhere(state, target, message) do
    pid = route_of(state, target)

    case message do
      {:call, from, _} when pid == nil ->
        GenServer.reply(from, Valimc.Data.Error.retry(:stale_owner))
        {:noreply, state}

      {:call, from, call} ->
        relays = :gen_server.reqids_add(:gen_server.send_request(pid, call), from, state.relays)
        {:noreply, %{state | relays: relays}}

      {:info, info} ->
        if pid, do: send(pid, info)
        {:noreply, state}
    end
  end

  defp relayed(state, message) do
    case :gen_server.check_response(message, state.relays, true) do
      {result, from, relays} ->
        retry = Valimc.Data.Error.retry(:region_unavailable)
        GenServer.reply(from, with({:reply, reply} <- result, do: reply, else: (_ -> retry)))
        {:ok, %{state | relays: relays}}

      _ ->
        :none
    end
  end

  defp route_of(state, {:key, {sx, sz}}),
    do: other(Valimc.World.Directory.lookup({state.dimension, sx, sz}))

  defp route_of(_state, {:epoch, epoch}),
    do: other(Valimc.World.Directory.epoch_owner(epoch))

  defp route_of(_state, _), do: nil

  defp other({pid, _, _}), do: other(pid)
  defp other(pid) when is_pid(pid) and pid != self(), do: pid
  defp other(_), do: nil

  ## Messages

  @impl true
  def handle_info({:player, uuid, message}, state),
    do: {:noreply, Host.info(state, uuid, message)}

  def handle_info({:player_checkpointed, uuid, ref, seq, result}, state),
    do: {:noreply, Host.checkpointed(state, uuid, ref, seq, result)}

  def handle_info({:player_closed, uuid, _result}, state),
    do: state |> Host.closed(uuid) |> retire()

  # A session's job timer or task reply (`Valimc.Player.Jobs`) comes to the
  # group that started it.
  def handle_info({:job_timeout, _, _} = message, state), do: claim(state, message)
  def handle_info({ref, _} = message, state) when is_reference(ref), do: claim(state, message)

  # A relayed call's answer (`elsewhere/3`) goes to its caller.
  def handle_info({[:alias | _], _} = message, state) do
    case relayed(state, message) do
      {:ok, state} -> retire(state)
      :none -> claim(state, message)
    end
  end

  def handle_info({:tick, token}, %{tick_clock: %{token: token}} = state) do
    now = System.monotonic_time(:millisecond)

    case TickClock.advance(state.tick_clock, token, now) do
      :stale ->
        {:noreply, state}

      {:early, clock, delay} ->
        {:noreply, schedule_tick(state, clock, delay)}

      {:ok, clock, late, delay} ->
        clock = %{clock | tick: next_tick(state)}

        # A frozen game (`/tick freeze`) runs only the steps it is granted.
        case Valimc.World.TickRate.run?(state.tick_steps) do
          {true, steps} ->
            Valimc.Data.Metrics.add(:region_ticks)
            Valimc.Data.Metrics.add(:region_late_milliseconds, late)
            started = System.monotonic_time(:nanosecond)
            state = run_tick(%{state | tick_clock: clock, tick_steps: steps}, clock.tick, now)
            Valimc.World.TickRate.sample(System.monotonic_time(:nanosecond) - started)
            lifecycle(state, delay, now)

          {false, steps} ->
            lifecycle(
              %{state | tick_steps: steps, tick_clock: %{clock | tick: state.tick_clock.tick}},
              delay,
              now
            )
        end
    end
  end

  def handle_info({:tick, _}, state), do: {:noreply, state}

  # The commit timer cuts the sections changed since the last cut; once a
  # second every section, for what is due by time alone (item motion, a
  # checkpoint): a timer's cost follows what changed (VMC-077w).
  def handle_info(:commit, state) do
    sweep = rem(state.commits, @sweep_commits) == 0

    keys =
      if sweep,
        do: Map.keys(state.sections),
        else: Enum.filter(state.touched, &Map.has_key?(state.sections, &1))

    state =
      Enum.reduce(keys, state, fn key, acc ->
        put_resource(acc, key, RegionData.commit_tick(acc.sections[key].resource))
      end)

    timer = Process.send_after(self(), :commit, state.commit_ms)
    state = %{state | commits: state.commits + 1}
    state = commit_frames(%{state | commit_timer: timer}, :players)
    {:noreply, if(state.players == %{}, do: state, else: Host.checkpoints(state))}
  end

  # A section's worker ended (`Valimc.World.Jobs`): reached like its reports.
  def handle_info({{:resource, epoch, :job_down}, ref, :process, _, reason}, state),
    do: handle_info({:resource, epoch, {:job_down, ref, reason}}, state)

  def handle_info({:resource, epoch, message} = info, state) do
    case state.epochs do
      %{^epoch => key} -> section_info(state, key, message)
      _ -> elsewhere(state, {:epoch, epoch}, {:info, info})
    end
  end

  def handle_info({:ticket, key, holder, type, chunks} = info, state)
      when is_pid(holder) and is_atom(type) and is_list(chunks) do
    if Map.has_key?(state.sections, key),
      do: section_info(state, key, {:ticket, holder, type, chunks}),
      else: elsewhere(state, {:key, key}, {:info, info})
  end

  # A view's tickets for this group's sections in one message: one commit
  # after all of them.
  def handle_info({:tickets, holder, entries}, state) when is_pid(holder) and is_list(entries) do
    entries
    |> Enum.reduce({:noreply, state}, fn
      {key, type, chunks}, {:noreply, acc} when is_atom(type) and is_list(chunks) ->
        if Map.has_key?(acc.sections, key),
          do: section_apply(acc, key, {:ticket, holder, type, chunks}),
          else: elsewhere(acc, {:key, key}, {:info, {:ticket, key, holder, type, chunks}})

      _, result ->
        result
    end)
    |> case do
      {:noreply, state} -> {:noreply, commit_frames(state)}
      stop -> stop
    end
  end

  # A delivery of full chunks from the generation scheduler (VMC-077w): each
  # section installs its chunks in one pass, the halo images its siblings get
  # apply once per sibling, everything commits once, and then the scheduler
  # may send the next delivery. Its credit is the account's it was sent to
  # (`credit`): sections that moved take it along, and their new group
  # acknowledges it once it installed them.
  def handle_info({:generated, scheduler, deliveries}, state),
    do: handle_info({:generated, scheduler, deliveries, self()}, state)

  def handle_info({:generated, scheduler, deliveries, credit}, state)
      when is_pid(scheduler) and is_list(deliveries) do
    {state, effects, strays} =
      Enum.reduce(deliveries, {state, [], %{}}, fn {key, epoch, fulls} = delivery,
                                                   {acc, effects, strays} ->
        case acc.epochs do
          %{^epoch => ^key} ->
            message = {:generated, scheduler, fulls}
            {:noreply, resource} = RegionData.handle_info(message, enter(acc, key))
            acc = put_resource(acc, key, %{resource | sibling_effects: []})
            {acc, effects ++ resource.sibling_effects, strays}

          _ ->
            case route_of(acc, {:epoch, epoch}) do
              nil -> {acc, effects, strays}
              pid -> {acc, effects, Map.update(strays, pid, [delivery], &[delivery | &1])}
            end
        end
      end)

    # One group takes the credit on; the others' parts carry none.
    case Enum.to_list(strays) do
      [] ->
        if credit, do: Valimc.Worldgen.Scheduler.delivered(scheduler, credit)

      [{pid, part} | rest] ->
        send(pid, {:generated, scheduler, Enum.reverse(part), credit})
        for {pid, part} <- rest, do: send(pid, {:generated, scheduler, Enum.reverse(part), nil})
    end

    {images, others} =
      Enum.split_with(effects, &match?({_, {:halo, {:images, _, _}}}, &1))

    halos =
      images
      |> Enum.group_by(&elem(&1, 0), fn {_, {:halo, {:images, _, list}}} -> list end)
      |> Enum.map(fn {key, lists} -> {key, {:halo, {:images, nil, Enum.concat(lists)}}} end)

    state =
      Enum.reduce(others ++ halos, state, fn {sibling, effect}, acc ->
        if Map.has_key?(acc.sections, sibling) do
          acc
          |> put_resource(sibling, RegionData.apply_sibling(enter(acc, sibling), effect))
          |> deliver_rules(sibling)
        else
          acc
        end
      end)

    {:noreply, commit_frames(state)}
  end

  def handle_info({:halo, key, payload} = info, state) do
    if Map.has_key?(state.sections, key),
      do: section_info(state, key, {:halo, payload}),
      else: elsewhere(state, {:key, key}, {:info, info})
  end

  # The log (VMC-077f): a record's acknowledgement names each section's or
  # player's frame in it; one commit after all of them. A transfer waiting for
  # frames to be durable is sent with the last one.
  def handle_info({:storage_durable, acks}, state) when is_list(acks) do
    acks
    |> Enum.reduce({:noreply, state}, fn
      {{:player, uuid}, seq}, {:noreply, acc} ->
        {:noreply, Host.durable(acc, uuid, seq)}

      {owner, seq}, {:noreply, acc} ->
        case acc.owners do
          %{^owner => key} -> section_apply(acc, key, {:storage_durable, seq})
          _ -> {:noreply, acc}
        end

      _, stop ->
        stop
    end)
    |> case do
      {:noreply, state} -> {:noreply, state |> send_ready() |> commit_frames()}
      stop -> stop
    end
  end

  def handle_info({:storage_failed, _owner, _seq, reason}, state),
    do: {:stop, {:storage_failed, reason}, state}

  # The log stripe went down: frames sent may or may not be durable.
  def handle_info({:DOWN, ref, :process, _, reason}, %{stripe: {_, ref, _}} = state) do
    if sending?(state),
      do: {:stop, {:storage_failed, {:log_down, reason}}, state},
      else: {:noreply, %{state | stripe: nil}}
  end

  # A relayed call's group, or a transfer's target before it held it,
  # stopped: the caller retries; the players resume here.
  def handle_info({:DOWN, ref, :process, _, _} = info, state) do
    with :none <- relayed(state, info),
         nil <- Enum.find(state.transfers, fn {_, transfer} -> transfer.monitor == ref end) do
      case Host.claim(state, info) do
        {:ok, state} -> {:noreply, state}
        :error -> broadcast(state, info)
      end
    else
      {:ok, state} -> retire(state)
      {id, _} -> resume(state, id)
    end
  end

  # A transfer to this group; players alone only to their section's group.
  def handle_info({:adopt, ref, from, sections, sessions}, state) do
    if sections == [] and not Enum.all?(sessions, &Host.home?(state, &1)) do
      send(from, {:refused, ref})
      {:noreply, state}
    else
      state = Enum.reduce(sections, %{state | retiring: false}, &adopt/2)
      state = Enum.reduce(sessions, state, &Host.host(&2, &1))
      send(from, {:held, ref})
      state = if sections == [], do: state, else: collect_soon(state)

      {:noreply,
       if(state.tick_timer, do: state, else: schedule_tick(state, state.tick_clock, 50))}
    end
  end

  def handle_info({:held, ref}, state) when is_map_key(state.transfers, ref) do
    {transfer, transfers} = Map.pop!(state.transfers, ref)
    Process.demonitor(transfer.monitor, [:flush])
    Host.released(transfer.players)
    retire(%{state | transfers: transfers})
  end

  def handle_info({:refused, ref}, state) when is_map_key(state.transfers, ref) do
    Process.demonitor(state.transfers[ref].monitor, [:flush])
    resume(state, ref)
  end

  # The regionizer retires this group: nothing is routed to it any more.
  def handle_info(:retire, state) do
    if idle?(state), do: {:stop, :normal, state}, else: {:noreply, %{state | retiring: false}}
  end

  # A section's state arrives as one large message; until a full collection
  # moves it out of the young heap, every minor collection copies it again
  # (twice the tick cost measured). One collection after a merge's adopts.
  def handle_info(:collect, state) do
    :erlang.garbage_collect()
    {:noreply, %{state | collect: false}}
  end

  def handle_info({:"ETS-TRANSFER", _table, _from, {:section, _key}}, state),
    do: {:noreply, state}

  # Untagged/stale callbacks never select a resource or change its data.
  def handle_info(_, state), do: {:noreply, state}

  defp claim(state, message) do
    case Host.claim(state, message) do
      {:ok, state} -> {:noreply, state}
      :error -> {:noreply, state}
    end
  end

  defp section_info(state, key, message) do
    case section_apply(state, key, message) do
      {:noreply, state} -> {:noreply, commit_frames(state)}
      stop -> stop
    end
  end

  defp section_apply(state, key, message) do
    case RegionData.handle_info(message, enter(state, key)) do
      {:noreply, resource} ->
        {:noreply, state |> put_resource(key, resource) |> deliver_rules(key)}

      {:stop, reason, resource} ->
        {:stop, reason, put_resource(state, key, resource)}
    end
  end

  # Every section sees it; each acts only on what is its own. One commit
  # after all of them.
  defp broadcast(state, message) do
    Map.keys(state.sections)
    |> Enum.reduce_while({:noreply, state}, fn key, {:noreply, acc} ->
      case section_apply(acc, key, message) do
        {:noreply, acc} -> {:cont, {:noreply, acc}}
        stop -> {:halt, stop}
      end
    end)
    |> case do
      {:noreply, state} -> {:noreply, commit_frames(state)}
      stop -> stop
    end
  end

  ## Ticks and lifecycle

  defp run_tick(state, tick, now) do
    state = state |> track_players() |> spawn_mobs(tick)

    state.sections
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(state, fn key, acc ->
      acc |> put_resource(key, TickPipeline.run(enter(acc, key), tick, now)) |> deliver_rules(key)
    end)
  end

  # Natural spawning and despawning (VMC-042a) over the group's sections,
  # before their entities tick, as vanilla's chunk source ticks before them.
  defp spawn_mobs(%{spawning: nil} = state, _tick), do: state
  defp spawn_mobs(state, _tick) when map_size(state.sections) == 0, do: state

  defp spawn_mobs(state, tick) do
    case Host.spawn_players(state) do
      [] ->
        state

      players ->
        resources = Map.new(state.sections, fn {key, s} -> {key, s.resource} end)

        group = %{
          sections: resources,
          stores: for({_, r} <- resources, do: r.blocks.ref),
          absent: Enum.flat_map(resources, fn {_, r} -> MapSet.to_list(r.generation.absent) end),
          players: players,
          spawning: state.spawning,
          environment: Spawning.environment(state.dimension),
          game_time: tick
        }

        {spawning, plan} = Spawning.plan(group)

        Enum.reduce(plan, %{state | spawning: spawning}, fn {key, {records, discards, resets}},
                                                            acc ->
          if Map.has_key?(acc.sections, key),
            do:
              put_resource(
                acc,
                key,
                RegionData.spawned(enter(acc, key), Enum.reverse(records), discards, resets)
              ),
            else: acc
        end)
    end
  end

  # Hosted players' trackers tick first; each section publishes the players
  # standing in it with its entities (VMC-077i4).
  defp track_players(state) do
    {state, published} = Host.track(state)
    targets = Host.targets(state)
    bodies = Host.bodies(state)

    Enum.reduce(state.sections, state, fn {key, section}, acc ->
      resource = section.resource

      case Map.fetch(published, key) do
        {:ok, players} ->
          put_resource(acc, key, RegionData.players(resource, players, targets, bodies))

        :error
        when resource.player_views == %{} and resource.player_targets == targets and
               resource.player_bodies == bodies ->
          acc

        :error ->
          put_resource(acc, key, RegionData.players(resource, {%{}, %{}}, targets, bodies))
      end
    end)
  end

  # An idle section without tickets unloads (VMC-077e): its route goes first,
  # then it saves what is volatile. Players outside the group's sections move
  # to their section's group; a group left with nothing retires.
  defp lifecycle(state, delay, now) do
    tick = state.tick_clock.tick

    state =
      Enum.reduce(Map.keys(state.sections), state, fn key, acc ->
        case RegionData.lifecycle(acc.sections[key].resource, tick, now) do
          {:ok, resource} -> put_resource(acc, key, resource)
          {:unload, resource} -> unload(put_resource(acc, key, resource), key)
        end
      end)

    # A section's own save can take the acknowledgement a transfer waits for.
    state = send_ready(state)
    state = Enum.reduce(Map.keys(state.players), state, &move_player(&2, &1)) |> commit_frames()
    state |> schedule_tick(state.tick_clock, delay) |> retire()
  end

  defp unload(state, key) do
    entry = state.sections[key]
    route = section(state, key)

    case Valimc.World.Directory.retire(route, entry.admission) do
      :ok ->
        Valimc.Data.Metrics.add(:region_unloads)
        state = commit_frames(state, true)
        RegionData.terminate(:normal, state.sections[key].resource)
        :ets.delete(entry.resource.publication)
        Registry.unregister(Valimc.RegionRegistry, route)
        Valimc.World.Directory.retired(route)

        if Valimc.config(:regionizer, key),
          do: Valimc.World.Regionizer.unloaded(state.dimension, key, self())

        drop_section(state, key)

      {:error, _} ->
        state
    end
  end

  # A group with nothing left asks the regionizer to retire it, once until
  # it adopts again.
  defp idle?(state),
    do:
      state.sections == %{} and state.players == %{} and state.player_leaving == %{} and
        state.transfers == %{} and state.outgoing == [] and
        :gen_server.reqids_size(state.relays) == 0

  defp retire(state) do
    cond do
      state.retiring or not idle?(state) ->
        {:noreply, state}

      Valimc.World.Regionizer.retire(state.dimension) == :ok ->
        {:noreply, %{state | retiring: true}}

      true ->
        {:stop, :normal, state}
    end
  end

  # A group with sections or players ticks on its timer, unless tests step it.
  defp schedule_tick(state, clock, delay) do
    if state.tick_timer, do: Process.cancel_timer(state.tick_timer)

    timer =
      if not state.manual and (state.sections != %{} or state.players != %{}),
        do: Process.send_after(self(), {:tick, clock.token}, delay)

    %{state | tick_clock: clock, tick_timer: timer}
  end

  ## Commits

  # Every section's and hosted player's frames from one cut go out as one
  # record: when any has frames to send, the others' changes are cut too, so a
  # callback's changes to the world and to a player are durable together.
  # Only sections changed since the last cut (`touched`) can have any: a cut
  # costs what changed, not the group's size (VMC-077w); the commit timer
  # sweeps every section once a second. `cut` true cuts everything now;
  # `:players` (the commit timer) cuts the players' changes. While a transfer
  # waits for what moves to be durable, nothing more is cut (`send_ready/1`).
  defp commit_frames(state, cut \\ false)
  defp commit_frames(%{outgoing: [_ | _]} = state, _cut), do: state

  defp commit_frames(state, cut) do
    keys = Enum.filter(state.touched, &Map.has_key?(state.sections, &1))

    pending? =
      cut == true or Enum.any?(keys, &(state.sections[&1].resource.storage.outbox != []))

    state =
      if (pending? or cut == :players) and state.players != %{}, do: Host.cut(state), else: state

    pending? = pending? or Host.pending?(state)

    cond do
      not pending? ->
        state

      true ->
        {frames, state} =
          Enum.reduce(keys, {[], state}, fn key, {frames, acc} ->
            resource = RegionData.cut(acc.sections[key].resource)
            {taken, storage} = RegionStorage.take(resource.storage)
            taken = for frame <- taken, do: {storage.base, frame}
            {[taken | frames], put_resource(acc, key, %{resource | storage: storage})}
          end)

        {players, state} = Host.take(state)
        frames = frames |> Enum.reverse() |> Enum.concat()
        send_frames(%{state | touched: MapSet.new()}, frames ++ players)
    end
  end

  # One record per world folder: one in play; tests give owners their own.
  defp send_frames(state, frames) do
    frames
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce(state, fn {base, frames}, acc ->
      # The stripe watched, unless it went down and its monitor has not said so.
      known =
        case acc.stripe do
          {pid, _, ^base} -> if Process.alive?(pid), do: pid
          _ -> nil
        end

      watch_stripe(acc, base, Log.commit_group(base, acc.route, frames, self(), known))
    end)
  end

  defp watch_stripe(%{stripe: {pid, _, base}} = state, base, pid), do: state

  defp watch_stripe(state, base, pid) do
    with {_, ref, _} <- state.stripe, do: Process.demonitor(ref, [:flush])
    %{state | stripe: {pid, Process.monitor(pid), base}}
  end

  ## Transfers

  @doc false
  # A hosted player standing outside the group's sections moves to its
  # section's group once that exists (`Valimc.Player.Host`).
  def move_player(state, uuid) do
    if player_target(state, uuid) != nil and {:player, uuid} not in state.outgoing,
      do: state |> commit_frames(true) |> queue({:player, uuid}),
      else: state
  end

  defp player_target(state, uuid) do
    with section when section != nil <- Host.destination(state, uuid),
         {:ok, {pid, _}} when pid != self() <- Valimc.World.existing_owner(section),
         do: pid,
         else: (_ -> nil)
  end

  # A transfer is sent once every frame the group sent is durable, so no
  # acknowledgement follows a section or player; until then it sends nothing
  # more, and frames cut meanwhile go along.
  defp queue(state, request), do: send_ready(%{state | outgoing: state.outgoing ++ [request]})

  defp send_ready(%{outgoing: []} = state), do: state

  defp send_ready(state) do
    if sending?(state),
      do: state,
      else: Enum.reduce(state.outgoing, %{state | outgoing: []}, &send_transfer/2)
  end

  # Whether frames the group sent are not yet durable.
  defp sending?(state),
    do:
      Host.sending?(state) or
        Enum.any?(state.sections, fn {_, s} -> RegionStorage.sending?(s.resource.storage) end)

  # Keys the regionizer named from reports behind this group: one unloaded
  # since is not handed over.
  defp send_transfer({:sections, from, target, keys}, state) do
    keys =
      if keys == :all,
        do: Map.keys(state.sections),
        else: Enum.filter(keys, &Map.has_key?(state.sections, &1))

    cond do
      keys == [] ->
        GenServer.reply(from, {:ok, []})
        state

      Process.alive?(target) ->
        riders = if map_size(state.sections) == length(keys), do: :all, else: {:keys, keys}
        Valimc.Data.Metrics.add(:region_handoffs, length(keys))
        state = transfer(state, target, keys, riders)
        # After the adopt: the regionizer's next order comes behind it.
        GenServer.reply(from, {:ok, keys})
        state

      true ->
        GenServer.reply(from, {:error, :invalid_handoff})
        state
    end
  end

  defp send_transfer({:player, uuid}, state) do
    case player_target(state, uuid) do
      nil ->
        state

      pid ->
        Valimc.Data.Metrics.add(:player_handoffs)
        transfer(state, pid, [], {:players, [uuid]})
    end
  end

  # Sections `keys` and players `riders` (`Host.take_players/2`) go to
  # `target` in one message; the players stay the group's until held.
  defp transfer(state, target, keys, riders) do
    sections =
      for key <- keys do
        %{resource: resource, admission: token} = state.sections[key]
        :ok = Native.region_give(resource.blocks.ref, target)
        true = :ets.give_away(resource.publication, target, {:section, key})
        Registry.unregister(Valimc.RegionRegistry, section(state, key))
        {key, token, %{resource | siblings: %{}}}
      end

    {players, state} = Host.take_players(state, riders)

    ref = make_ref()
    sessions = for {_, %{entry: entry}} <- players, do: entry.session
    send(target, {:adopt, ref, self(), sections, sessions})

    state =
      Enum.reduce(sections, state, fn {key, token, resource}, acc ->
        :ok =
          Valimc.World.Directory.move(section(acc, key), token, target, %{
            publication: resource.publication,
            epoch: resource.epoch
          })

        drop_section(acc, key)
      end)

    transfer = %{target: target, monitor: Process.monitor(target), players: players}
    %{state | transfers: Map.put(state.transfers, ref, transfer)}
  end

  # A section handed to this group continues at its tick and wants its
  # chunks from here.
  defp adopt({key, token, resource}, state) do
    state = put_section(state, key, token, RegionData.adopted(resource))
    {:ok, _} = Registry.register(Valimc.RegionRegistry, section(state, key), nil)

    if Valimc.config(:regionizer, key),
      do: Valimc.World.Regionizer.adopted(state.dimension, key, self())

    state = if state.tick_clock == nil, do: start_clock(state), else: catch_up(state, key)
    resource = Valimc.World.RegionGeneration.pump(state.sections[key].resource)
    put_resource(state, key, resource)
  end

  # The transfer `ref` failed before it was held: its players are this
  # group's again.
  defp resume(state, ref) do
    {transfer, transfers} = Map.pop!(state.transfers, ref)
    state = Host.resume(%{state | transfers: transfers}, transfer.players)
    state = if state.tick_timer, do: state, else: schedule_tick(state, state.tick_clock, 50)
    state |> commit_frames() |> retire()
  end

  defp collect_soon(%{collect: true} = state), do: state

  defp collect_soon(state) do
    send(self(), :collect)
    %{state | collect: true}
  end

  @impl true
  # A clean stop cuts every section's changes into one record first; each
  # section then saves (VMC-077f). A crash commits nothing more.
  def terminate(reason, state) do
    clean = reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)
    state = %{state | outgoing: []}
    state = if clean, do: Host.stop_all(state, &commit_frames(&1, true)), else: state
    state = if clean and state.sections != %{}, do: commit_frames(state, true), else: state

    for {_, section} <- state.sections, do: RegionData.terminate(reason, section.resource)
    :ok
  end
end
