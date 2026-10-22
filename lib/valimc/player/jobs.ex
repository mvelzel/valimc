defmodule Valimc.Player.Jobs do
  @moduledoc """
  Bounded asynchronous jobs owned by one session process: at most one job per
  kind, each with an optional deadline timer, a monitored task or process and a
  correlation reference. Replaces per-kind start/timer/monitor/result/DOWN/cancel
  bookkeeping; the owning domain module decides what each outcome means.

  A timed-out job's task or process is stopped. `classify/2` turns an incoming
  message into `{:result, kind, job, payload, jobs}`,
  `{:down, kind, job, reason, jobs}`, `{:timeout, kind, job, jobs}`, `:stale` (a
  message of a finished or replaced job) or `:unknown`.
  """

  defstruct active: %{}, refs: %{}

  @type kind :: atom()
  @type job :: %{
          required(:kind) => kind(),
          required(:ref) => reference(),
          optional(:task) => Task.t() | nil,
          optional(:pid) => pid() | nil,
          optional(:monitor) => reference() | nil,
          optional(:timer) => reference() | nil,
          optional(atom()) => term()
        }

  def new, do: %__MODULE__{}

  def active?(%__MODULE__{active: active}, kind), do: Map.has_key?(active, kind)
  def get(%__MODULE__{active: active}, kind), do: Map.get(active, kind)

  @doc """
  Register a job of `kind` (which must not be active). `target` is a `Task`, a pid
  to monitor, or nil (a reply-correlated job). Options: `timeout: ms` arms
  `{:job_timeout, kind, ref}`; `ref:` supplies the correlation reference; `data:`
  merges domain fields into the job map.
  """
  def track(%__MODULE__{} = jobs, kind, target, opts \\ []) do
    if active?(jobs, kind), do: raise(ArgumentError, "job #{inspect(kind)} already active")
    ref = Keyword.get_lazy(opts, :ref, &make_ref/0)

    timer =
      case Keyword.get(opts, :timeout) do
        nil -> nil
        ms -> Process.send_after(self(), {:job_timeout, kind, ref}, max(ms, 0))
      end

    job =
      Map.merge(Keyword.get(opts, :data, %{}), %{
        kind: kind,
        ref: ref,
        task: nil,
        pid: nil,
        monitor: nil,
        timer: timer
      })
      |> put_target(target)

    {%{jobs | active: Map.put(jobs.active, kind, job)} |> index(job), job}
  end

  @doc "Merge domain fields into an active job."
  def update(%__MODULE__{} = jobs, kind, fields) when is_map(fields) do
    case get(jobs, kind) do
      nil -> jobs
      job -> %{jobs | active: Map.put(jobs.active, kind, Map.merge(job, fields))}
    end
  end

  @doc "Classify an incoming message; a completed job is removed (its monitor flushed)."
  def classify(%__MODULE__{} = jobs, {:job_timeout, kind, ref}) do
    case get(jobs, kind) do
      %{ref: ^ref} = job ->
        # An expired job's task or process is stopped; a late reply is then unknown.
        stop_target(job)
        {:timeout, kind, job, remove(jobs, job, true)}

      _ ->
        :stale
    end
  end

  def classify(%__MODULE__{} = jobs, {:DOWN, monitor, :process, _pid, reason}) do
    case Map.get(jobs.refs, monitor) do
      nil -> :unknown
      kind -> {:down, kind, jobs.active[kind], reason, remove(jobs, jobs.active[kind], false)}
    end
  end

  def classify(%__MODULE__{} = jobs, {ref, payload}) when is_reference(ref) do
    case Map.get(jobs.refs, ref) do
      nil ->
        :unknown

      kind ->
        job = jobs.active[kind]
        {:result, kind, job, payload, remove(jobs, job, true)}
    end
  end

  def classify(%__MODULE__{}, _message), do: :unknown

  @doc "Cancel one job: timer, task/process and monitor. Returns `{job | nil, jobs}`."
  def cancel(%__MODULE__{} = jobs, kind) do
    case get(jobs, kind) do
      nil ->
        {nil, jobs}

      job ->
        stop_target(job)
        {job, remove(jobs, job, true)}
    end
  end

  @doc "Cancel every job (terminate)."
  def cancel_all(%__MODULE__{} = jobs) do
    Enum.reduce(Map.keys(jobs.active), jobs, fn kind, acc -> elem(cancel(acc, kind), 1) end)
  end

  defp put_target(job, nil), do: job
  defp put_target(job, %Task{} = task), do: %{job | task: task, pid: task.pid}
  defp put_target(job, pid) when is_pid(pid), do: %{job | pid: pid, monitor: Process.monitor(pid)}

  defp stop_target(%{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)

  defp stop_target(%{pid: pid, monitor: monitor}) when is_pid(pid) do
    Process.demonitor(monitor, [:flush])
    Process.exit(pid, :kill)
  end

  defp stop_target(_), do: :ok

  defp index(jobs, job) do
    refs =
      [job.ref, job.task && job.task.ref, job.monitor]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(jobs.refs, &Map.put(&2, &1, job.kind))

    %{jobs | refs: refs}
  end

  defp unindex(jobs, job),
    do: %{jobs | refs: Map.drop(jobs.refs, [job.ref, job.task && job.task.ref, job.monitor])}

  defp remove(jobs, job, flush?) do
    if job.timer, do: Process.cancel_timer(job.timer)

    if flush? do
      if job.task, do: Process.demonitor(job.task.ref, [:flush])
      if job.monitor, do: Process.demonitor(job.monitor, [:flush])
    end

    jobs = unindex(jobs, job)
    %{jobs | active: Map.delete(jobs.active, job.kind)}
  end
end
