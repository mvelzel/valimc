defmodule Valimc.World.Jobs do
  @moduledoc """
  An owner's background jobs (VMC-077g): one table, at most one job per kind.
  A job is a worker under a bounded task supervisor with a token, a monitor
  and an optional deadline. The worker reports `{:job, kind, token, result}`
  and an overrun sends `{:job_deadline, kind, token}`, both through the
  owner's `wrap` (a region tags them with its epoch, so a replaced owner's
  reports are dropped). A report whose token is not the running job's is
  stale and ignored.

  A job may instead take one of a fixed number of slots (`init_slots!/2`):
  its worker is spawned at once, without a call to a supervisor (VMC-077w: an
  owner's hot path never waits on another process), and frees its slot as it
  ends. Such a worker is never killed, so it always frees its slot: it takes
  no deadline, and `stop_all/1` lets it finish.

  The owner keeps what a job needs to adopt its result in the job's `data`;
  `monitors` maps each worker's monitor to its kind, so an owner can route a
  `:DOWN` message with a guard.
  """

  defstruct entries: %{}, monitors: %{}

  @type job :: %{
          kind: atom(),
          token: reference(),
          pid: pid(),
          monitor: reference(),
          timer: reference() | nil,
          data: map()
        }

  @doc "Create slots `name` for at most `max` workers at once (application start)."
  def init_slots!(name, max) when is_atom(name) and max > 0,
    do: :persistent_term.put({__MODULE__, name}, {:counters.new(1, [:write_concurrency]), max})

  @doc """
  Start `work.()` as job `kind`. Options: `:supervisor` (a
  `Task.Supervisor`) or `:slots` (a name of `init_slots!/2`), `:deadline`
  (ms, or nil; not with slots), `:wrap` (message => message sent to the
  owner), `:link` (the worker dies with its owner), `:data`.
  `{:error, {:retry, :workers_busy}}` when the pool is full; a kind already
  running is a programming error.
  """
  def start(%__MODULE__{} = jobs, kind, work, opts) when is_function(work, 0) do
    if Map.has_key?(jobs.entries, kind), do: raise(ArgumentError, "job #{kind} is running")
    owner = self()
    token = make_ref()
    wrap = Keyword.get(opts, :wrap, & &1)
    link = Keyword.get(opts, :link, false)
    slots = Keyword.get(opts, :slots)

    run =
      Valimc.World.Dimension.bind(fn ->
        if link, do: Process.link(owner)
        send(owner, wrap.({:job, kind, token, work.()}))
      end)

    case if(slots, do: spawn_slot(slots, run), else: supervised(opts, run)) do
      {:ok, pid} ->
        timer =
          case Keyword.get(opts, :deadline) do
            nil -> nil
            ms -> Process.send_after(owner, wrap.({:job_deadline, kind, token}), ms)
          end

        job = %{
          kind: kind,
          token: token,
          pid: pid,
          monitor: Process.monitor(pid),
          timer: timer,
          kill: slots == nil,
          data: Keyword.get(opts, :data, %{})
        }

        {:ok,
         %{
           jobs
           | entries: Map.put(jobs.entries, kind, job),
             monitors: Map.put(jobs.monitors, job.monitor, kind)
         }, job}

      {:error, _} ->
        {:error, {:retry, :workers_busy}}
    end
  end

  defp supervised(opts, run),
    do: Task.Supervisor.start_child(Keyword.fetch!(opts, :supervisor), run)

  defp spawn_slot(name, run) do
    {counter, max} = :persistent_term.get({__MODULE__, name})

    if :counters.get(counter, 1) >= max do
      {:error, :busy}
    else
      :counters.add(counter, 1, 1)

      {:ok,
       spawn(fn ->
         try do
           run.()
         after
           :counters.sub(counter, 1, 1)
         end
       end)}
    end
  end

  @doc "The running job of `kind`, or nil."
  def get(%__MODULE__{entries: entries}, kind), do: Map.get(entries, kind)

  def running?(%__MODULE__{entries: entries}, kind), do: Map.has_key?(entries, kind)
  def busy?(%__MODULE__{entries: entries}), do: map_size(entries) > 0

  @doc """
  The job reported (`token`): `{:ok, job, jobs}` with its timer and monitor
  gone, or `:stale`.
  """
  def finish(%__MODULE__{} = jobs, kind, token) do
    case jobs.entries do
      %{^kind => %{token: ^token} = job} -> {:ok, close(job), drop(jobs, kind)}
      _ -> :stale
    end
  end

  @doc "The job overran its deadline: killed, `{:ok, job, jobs}`, or `:stale`."
  def expire(%__MODULE__{} = jobs, kind, token) do
    case finish(jobs, kind, token) do
      {:ok, job, jobs} ->
        Process.exit(job.pid, :kill)
        {:ok, job, jobs}

      :stale ->
        :stale
    end
  end

  @doc "A monitored worker went down without reporting: `{:ok, job, jobs}` or `:none`."
  def down(%__MODULE__{} = jobs, monitor) do
    case jobs.monitors do
      %{^monitor => kind} -> {:ok, close(jobs.entries[kind]), drop(jobs, kind)}
      _ -> :none
    end
  end

  @doc "Stop every job (the owner stops)."
  def stop_all(%__MODULE__{entries: entries}) do
    for {_, job} <- entries do
      close(job)
      if job.kill, do: Process.exit(job.pid, :kill)
    end

    %__MODULE__{}
  end

  defp close(job) do
    if job.timer, do: Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    job
  end

  defp drop(jobs, kind) do
    {job, entries} = Map.pop!(jobs.entries, kind)
    %{jobs | entries: entries, monitors: Map.delete(jobs.monitors, job.monitor)}
  end
end
