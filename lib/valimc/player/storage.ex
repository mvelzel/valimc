defmodule Valimc.Player.Storage do
  @moduledoc """
  A player's durability (VMC-077i3). The player is a storage owner
  `{:player, uuid}` like a region section: its file is the checkpoint of its
  keyed records (`Valimc.Player.State`), and the group that hosts its session
  cuts the records that changed into a frame of the group's own commit
  (`Valimc.World.Region`), so a player's changes and the world's changes of
  one callback (a pickup, a click, a death's drops) are durable together or
  not at all.

  - **Frames.** Records that move every tick while a player plays (the pose,
    motion, health, food, air, fire, freezing, effects and portal cooldown)
    go into a frame at most once a second; any other change cuts a frame at
    once and carries them along. A crash rolls back at most that second.
  - **Checkpoints.** The file is replaced (`Valimc.Storage.Checkpoint`)
    after #{1200} frames or 1 MiB of them, on `/save-all` and when the
    player leaves; the log then forgets the frames it holds. Loading reads
    the file and the frames after it, and folds them into the file at once.
  - **Holders.** The group hosting the session (until it lets the player go
    or the file holds its last frame) and a recovery fold register under the
    uuid (`Valimc.PlayerRegistry`, `host/1`); a login waits until none does.
    A session moves only once every frame it sent is durable (VMC-077y).
  """
  require Logger
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Storage.{Checkpoint, Log}
  alias Valimc.World.RegionStorage

  @registry Valimc.PlayerRegistry
  @volatile [
    :pose,
    :velocity,
    :fall_distance,
    :health,
    :absorption,
    :food,
    :air_supply,
    :fire_ticks,
    :frozen_ticks,
    :effects,
    :portal_cooldown,
    :time_since_rest
  ]
  @volatile_ms 1000
  @checkpoint_frames 1200
  @checkpoint_bytes 1024 * 1024
  @wait_ms 10_000

  defstruct [
    :base,
    :uuid,
    :owner,
    :path,
    seq: 0,
    # The records as of `seq` (without the uuid the file adds).
    committed: %{},
    checkpoint_seq: 0,
    frames_since: 0,
    bytes_since: 0,
    checkpointing: nil,
    requested: false,
    volatile_at: 0,
    # Frames cut and not yet sent (`[{owner, seq, frame}]`, newest first)
    # and what waits for frames in flight.
    outbox: [],
    in_flight: %{},
    waits: []
  ]

  def path(nil, _uuid), do: nil
  def path(base, <<_::128>> = uuid), do: Checkpoint.path(base, {:player, uuid})

  ## Login

  @doc """
  Wait until no process holds `uuid`'s state (a leaving session's last frame
  is durable and in its file), then load it: `{:ok, storage, state}`, with
  `state` nil for a new player, or `{:error, reason}`.
  """
  def load(<<_::128>> = uuid) do
    with :ok <- released(uuid, System.monotonic_time(:millisecond) + @wait_ms),
         do: read(Valimc.config(:world_path, uuid), uuid)
  end

  defp released(uuid, deadline) do
    cond do
      Registry.lookup(@registry, uuid) == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :player_still_saving}

      true ->
        Process.sleep(10)
        released(uuid, deadline)
    end
  end

  @doc "Read `uuid`'s file and frames under `base`, folding the frames into the file."
  def read(nil, uuid), do: {:ok, %__MODULE__{uuid: uuid, owner: {:player, uuid}}, nil}

  def read(base, uuid) do
    owner = {:player, uuid}
    path = path(base, uuid)

    with {:ok, {seq, records}} <- read_file(path),
         frames when is_list(frames) <- Log.frames(base, owner, seq) do
      records =
        RegionStorage.fold(
          records,
          for({_, frame} <- frames, do: :erlang.binary_to_term(frame))
        )

      last = frames |> List.last({seq, nil}) |> elem(0)

      storage = %__MODULE__{
        base: base,
        uuid: uuid,
        owner: owner,
        path: path,
        seq: last,
        checkpoint_seq: last,
        committed: Map.delete(records, {:player, :uuid})
      }

      if records == %{} do
        {:ok, storage, nil}
      else
        with {:ok, state} <-
               PlayerState.from_records(Map.put_new(records, {:player, :uuid}, uuid), uuid),
             :ok <- if(frames == [], do: :ok, else: write(storage)),
             do: {:ok, storage, state}
      end
    end
  end

  defp read_file(path) do
    case File.read(path, [:raw]) do
      {:ok, bytes} when byte_size(bytes) > 4_194_304 ->
        {:error, :invalid_player_file}

      {:ok, bytes} ->
        case Checkpoint.decode(bytes) do
          {:ok, %{seq: seq, records: records}} -> {:ok, {seq, records}}
          _ -> {:error, :invalid_player_file}
        end

      {:error, :enoent} ->
        {:ok, {0, %{}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The stripe found frames of `uuid` its file does not hold (a crash came
  before the checkpoint): fold them, unless a session holds the player.
  """
  def recover(base, uuid) do
    Task.start(fn ->
      {:ok, _} = Registry.register(@registry, uuid, :recovering)

      if Enum.all?(Registry.lookup(@registry, uuid), fn {pid, _} -> pid == self() end),
        do: read(base, uuid)
    end)
  end

  ## The hosting group

  @doc "The hosting group holds the player's state from now on."
  def hold(%__MODULE__{uuid: uuid}) do
    {:ok, _} = Registry.register(@registry, uuid, :hosted)
    :ok
  end

  @doc "This group no longer holds the player's state."
  def release(%__MODULE__{uuid: uuid}), do: Registry.unregister(@registry, uuid)

  @doc "Another group hosting `uuid`, or nil."
  def host(<<_::128>> = uuid) do
    Enum.find_value(Registry.lookup(@registry, uuid), fn {pid, value} ->
      if value == :hosted and pid != self(), do: pid
    end)
  end

  @doc """
  Cut a frame of `state`'s records that changed (`full` includes the
  volatile ones however recent): `{:ok, storage}`, or `{:error, reason}`
  when a record is one the file may not hold.
  """
  def cut(storage, state, full \\ false)

  def cut(%{base: nil} = storage, _state, _full), do: {:ok, %{storage | waits: []}}

  def cut(storage, state, full) do
    now = System.monotonic_time(:millisecond)
    records = PlayerState.records(state)
    committed = storage.committed

    changed =
      for({key, value} <- records, Map.get(committed, key, :none) !== value, do: key) ++
        for key <- Map.keys(committed), not Map.has_key?(records, key), do: key

    {volatile, lasting} = Enum.split_with(changed, &volatile?/1)

    keys =
      cond do
        lasting != [] or full -> changed
        volatile != [] and now >= storage.volatile_at -> volatile
        true -> []
      end

    cond do
      keys == [] ->
        {:ok, storage}

      (reason = invalid(state, lasting)) != nil ->
        {:error, reason}

      true ->
        ops =
          for key <- keys do
            case records do
              %{^key => value} -> {:put, key, value}
              _ -> {:del, key}
            end
          end

        frame = :erlang.term_to_binary(ops)
        seq = storage.seq + 1

        {:ok,
         %{
           storage
           | seq: seq,
             committed: RegionStorage.fold(committed, [ops]),
             outbox: [{storage.owner, seq, frame} | storage.outbox],
             in_flight: Map.put(storage.in_flight, seq, storage.waits),
             waits: [],
             frames_since: storage.frames_since + 1,
             bytes_since: storage.bytes_since + byte_size(frame),
             volatile_at: if(volatile != [], do: now + @volatile_ms, else: storage.volatile_at)
         }}
    end
  end

  defp volatile?({:player, field}), do: field in @volatile
  defp volatile?(_), do: false

  # Only records that changed are checked; a frame of volatile records alone
  # checks the pose (the rest are bounded where they change).
  defp invalid(state, []) do
    if PlayerState.valid_pose?(state.pose), do: nil, else: :invalid_pose
  end

  defp invalid(state, _lasting) do
    case PlayerState.validate(nil, state) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  @doc """
  Run `item` (`{:reply, from, reply}` or `{:closed, ref}`) once every frame
  cut so far is durable: `{:now, storage}` when none is in flight.
  """
  def after_durable(storage, item) do
    case Map.keys(storage.in_flight) do
      [] ->
        {:now, storage}

      seqs ->
        last = Enum.max(seqs)
        {:later, %{storage | in_flight: Map.update!(storage.in_flight, last, &(&1 ++ [item]))}}
    end
  end

  defdelegate take(storage), to: RegionStorage
  defdelegate sending?(storage), to: RegionStorage
  defdelegate durable(storage, seq), to: RegionStorage

  ## Checkpoints

  @doc "Ask for a checkpoint as soon as one may run (`/save-all`)."
  def request_checkpoint(storage), do: %{storage | requested: true}

  @doc "Whether a checkpoint is due and may run: every frame durable, none running."
  def checkpoint_due?(storage) do
    storage.base != nil and storage.checkpointing == nil and storage.outbox == [] and
      map_size(storage.in_flight) == 0 and storage.seq > storage.checkpoint_seq and
      Valimc.World.Saving.auto?() and
      (storage.requested or storage.frames_since >= @checkpoint_frames or
         storage.bytes_since >= @checkpoint_bytes)
  end

  @doc """
  Write the file off the group: `notify` (the group) receives
  `{:player_checkpointed, uuid, ref, seq, result}`.
  """
  def checkpoint(storage, notify) do
    ref = make_ref()
    job = %{storage | outbox: [], in_flight: %{}, waits: []}

    {:ok, _} =
      Task.start(fn ->
        send(notify, {:player_checkpointed, job.uuid, ref, job.seq, write(job)})
      end)

    %{storage | checkpointing: ref, requested: false}
  end

  @doc "A checkpoint finished."
  def checkpointed(%{checkpointing: ref} = storage, ref, seq, :ok),
    do: %{
      storage
      | checkpointing: nil,
        checkpoint_seq: seq,
        frames_since: storage.seq - seq,
        bytes_since: 0
    }

  def checkpointed(%{checkpointing: ref} = storage, ref, _seq, {:error, reason}) do
    Logger.error("Player checkpoint failed: #{inspect(reason)}")
    %{storage | checkpointing: nil}
  end

  def checkpointed(storage, _ref, _seq, _result), do: storage

  @doc """
  Close a leaving player's storage once its last frame is durable: the file
  holds every frame, then this group releases the player. Runs off the group;
  `reply` (a connection's call) is answered after.
  """
  def close(storage, group, reply) do
    {:ok, _} =
      Task.start(fn ->
        result = close_now(storage)
        send(group, {:player_closed, storage.uuid, result})
        if reply, do: GenServer.reply(reply, result)
      end)

    :ok
  end

  @doc "Close a leaving player's storage here and now (a group's clean stop)."
  def close_now(storage),
    do: if(storage.seq > storage.checkpoint_seq, do: write(storage), else: :ok)

  defp write(%{base: nil}), do: :ok

  defp write(storage) do
    records = Map.put(storage.committed, {:player, :uuid}, storage.uuid)

    with :ok <- Checkpoint.write(storage.path, storage.seq, records) do
      Log.covered(storage.base, storage.owner, storage.seq)
      Valimc.Data.Metrics.add(:player_saves)
      :ok
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
