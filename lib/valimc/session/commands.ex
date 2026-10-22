defmodule Valimc.Session.Commands do
  @moduledoc """
  Chat throttling and chat commands (VMC-069, VMC-053, VMC-077a).

  A command runs as the connection's `:command` job (`Valimc.Player.Jobs`): a
  task of `Valimc.CommandWorkers` with a snapshot of the player as its source
  (`Valimc.Commands.run/2`), so an owner that is slow or gone never blocks or
  kills the connection. The connection keeps handling packets meanwhile; the
  command changes its player through `{:command_op, …}` calls like any other
  target's and sends feedback through the mailbox. Commands run one at a time
  in the order they arrived; up to eight wait behind the running one. A command
  that crashes, exits or outlives its deadline ends as `command.failed`.

  Suggestions (`command_suggestion`) run the same way as a `:suggestion` job,
  since providers read owners (admin lists, stopwatches). While one runs, only
  the latest request waits: the client keeps only the answer to its latest id.
  """

  import Valimc.Protocol.Codec, only: [reject: 2]
  alias Valimc.Session.ChatThrottle
  alias Valimc.Commands.{Feedback, Source}
  alias Valimc.Text
  alias Valimc.Player.Jobs

  @queue 8
  @deadline 60_000

  def throttle_chat(state) do
    case ChatThrottle.record(state.chat_throttle) do
      {:ok, throttle} -> %{state | chat_throttle: throttle}
      {:spam, _} -> reject(state, "Kicked for spamming")
    end
  end

  @doc "Run `input` (without `/`) now, or after the commands before it."
  def command(state, input) do
    case Jobs.get(state.jobs, :command) do
      nil ->
        start(state, input, [])

      %{queue: queue} when length(queue) >= @queue ->
        Feedback.failure(Source.player(state), Text.literal("Too many commands at once"))
        state

      %{queue: queue} ->
        %{state | jobs: Jobs.update(state.jobs, :command, %{queue: queue ++ [input]})}
    end
  end

  defp start(state, input, queue) do
    source = Source.player(state)

    task =
      Task.Supervisor.async_nolink(Valimc.CommandWorkers, fn ->
        Valimc.Commands.run(source, input)
      end)

    {jobs, _job} =
      Jobs.track(state.jobs, :command, task,
        timeout: @deadline,
        data: %{queue: queue, input: input}
      )

    %{state | jobs: jobs}
  end

  @doc "Answer the suggestion request `id` for `text`, now or after the one running."
  def suggest(state, id, text) do
    case Jobs.get(state.jobs, :suggestion) do
      nil ->
        source = Source.player(state)

        task =
          Task.Supervisor.async_nolink(Valimc.CommandWorkers, fn ->
            Valimc.Commands.Suggestions.packet(
              id,
              Valimc.Commands.Suggestions.suggest(text, source)
            )
          end)

        {jobs, _job} =
          Jobs.track(state.jobs, :suggestion, task, timeout: 5000, data: %{next: nil})

        %{state | jobs: jobs}

      _running ->
        %{state | jobs: Jobs.update(state.jobs, :suggestion, %{next: {id, text}})}
    end
  end

  @doc "The suggestion `job` ended with `packet` (nil when it failed); the latest waiting one starts."
  def suggested(state, job, packet) do
    if packet, do: Valimc.Protocol.Codec.send_packets(state, [packet])

    case job.next do
      nil -> state
      {id, text} -> suggest(state, id, text)
    end
  end

  @doc "The command `job` ended (`outcome`: `:ok`, or why it failed); the next one starts."
  def finished(state, job, outcome) do
    if outcome != :ok do
      reason = if outcome == :timeout, do: "timed out", else: Exception.format_exit(outcome)
      Valimc.Commands.failed(Source.player(state), reason, "/#{job.input}: #{reason}")
    end

    case job.queue do
      [] -> state
      [next | rest] -> start(state, next, rest)
    end
  end
end
