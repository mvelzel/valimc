defmodule Valimc.World.Jobs do
  @moduledoc """
  An owner's background jobs (VMC-077g): one table, at most one job per kind.
  A job is a worker with a token, a monitor and an optional deadline. Its
  report `{:job, kind, token, result}`, an overrun `{:job_deadline, kind,
  token}` and its monitor's message (tagged `wrap.(:job_down)`) all go
  through the owner's `wrap`: a region tags them with its epoch, so they
  reach the section by its route. Stale tokens and monitors are ignored.

  A job runs under a bounded task supervisor or takes one of a fixed number
  of slots (`init_slots!/2`), spawned without a call (VMC-077w); it frees its
  slot as it ends, or its owner does for one killed from outside. The owner
  keeps what a job needs in its `data`; an owner a section moved to watches
  its jobs again (`watch/1`).
  """

  defstruct entries: %{}, monitors: %{}

  @type job :: %{
          kind: atom(),
          token: reference(),
          pid: pid(),
          monitor: reference(),
          tag: term(),
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
  owner), `:reply_to` (the owner to report to, asked when the work is done:
  a section's current group), `:link` (the worker dies with its owner),
  `:data`.
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
    reply_to = Keyword.get(opts, :reply_to, fn -> owner end)

    run =
      Valimc.World.Dimension.bind(fn ->
        if link, do: Process.link(owner)
        result = work.()
        send(reply_to.(), wrap.({:job, kind, token, result}))
      end)

    case if(slots, do: spawn_slot(slots, run), else: supervised(opts, run)) do
      {:ok, pid} ->
        expiry = wrap.({:job_deadline, kind, token})

        timer =
          case Keyword.get(opts, :deadline) do
            nil -> nil
            ms -> Process.send_after(owner, expiry, ms)
          end

        tag = wrap.(:job_down)

        job = %{
          kind: kind,
          token: token,
          pid: pid,
          monitor: :erlang.monitor(:process, pid, tag: tag),
          tag: tag,
          # Monitors of the owners the job's section left (`watch/1`).
          before: [],
          timer: timer,
          expiry: expiry,
          slots: slots,
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

  # The worker frees its slot as it ends, a failure too (then it exits with
  # `{:slot, reason}`).
  defp spawn_slot(name, run) do
    {counter, max} = :persistent_term.get({__MODULE__, name})

    if :counters.get(counter, 1) >= max do
      {:error, :busy}
    else
      :counters.add(counter, 1, 1)

      {:ok,
       spawn(fn ->
         result =
           try do
             run.()
           catch
             kind, reason -> {:failed, Exception.normalize(kind, reason, __STACKTRACE__)}
           end

         :counters.sub(counter, 1, 1)
         with {:failed, reason} <- result, do: exit({:slot, reason})
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

  @doc """
  A worker went down (`reason`) without reporting: `{:ok, job, jobs}`, or
  `:none` for a job that already reported.
  """
  def down(%__MODULE__{} = jobs, monitor, reason) do
    case jobs.monitors do
      # A worker that ended normally reported first, and one gone before
      # this owner watched it is seen by its old owner's monitor: either
      # message comes by the section's route, maybe after this one.
      %{^monitor => _} when reason in [:normal, :noproc] ->
        :none

      %{^monitor => kind} ->
        job = close(jobs.entries[kind])
        free(job, reason)
        {:ok, job, drop(jobs, kind)}

      _ ->
        :none
    end
  end

  # A slot worker stopped from outside never ran its end.
  defp free(%{slots: nil}, _reason), do: :ok
  defp free(_job, {:slot, _}), do: :ok

  defp free(%{slots: name}, _reason) do
    {counter, _} = :persistent_term.get({__MODULE__, name})
    :counters.sub(counter, 1, 1)
  end

  @doc """
  The section arrived at this owner: its workers and deadlines are watched
  from here, and its old owner's monitors still count.
  """
  def watch(%__MODULE__{} = jobs) do
    entries =
      Map.new(jobs.entries, fn {kind, job} ->
        timer =
          with ref when ref != nil <- job.timer,
               ms when is_integer(ms) <- Process.cancel_timer(ref),
               do: Process.send_after(self(), job.expiry, ms),
               else: (_ -> nil)

        monitor = :erlang.monitor(:process, job.pid, tag: job.tag)
        {kind, %{job | monitor: monitor, timer: timer, before: [job.monitor | job.before]}}
      end)

    monitors = Map.new(entries, fn {kind, job} -> {job.monitor, kind} end)
    %{jobs | entries: entries, monitors: Map.merge(jobs.monitors, monitors)}
  end

  @doc "Stop every job (the owner stops)."
  def stop_all(%__MODULE__{entries: entries}) do
    for {_, job} <- entries do
      close(job)
      if job.slots == nil, do: Process.exit(job.pid, :kill)
    end

    %__MODULE__{}
  end

  # The monitor's message of a worker that reported may still come: its
  # owner ignores it (`down/3`) instead of scanning its mailbox for it.
  defp close(job) do
    if job.timer, do: Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor)
    job
  end

  defp drop(jobs, kind) do
    {job, entries} = Map.pop!(jobs.entries, kind)
    %{jobs | entries: entries, monitors: Map.drop(jobs.monitors, [job.monitor | job.before])}
  end
end
