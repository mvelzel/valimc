defmodule Valimc.World.LightUpdates do
  @moduledoc "Bounded, coalesced halo light packet jobs over immutable images and chunk versions."
  import Bitwise, only: [|||: 2]
  alias Valimc.World.{Blocks, Jobs, LightHalo, RegionData}

  @batch 4

  def merge(pending, chunk, {scope, sky, block}) do
    Map.update(pending, chunk, {scope, sky, block}, fn {old, a, b} ->
      {if(scope == :all or old == :all, do: :all, else: :border), sky ||| a, block ||| b}
    end)
  end

  def queue(state, changes, scope) do
    pending =
      Enum.reduce(changes, state.light_pending, fn {chunk, sky, block}, acc ->
        if MapSet.member?(state.served, chunk),
          do: merge(acc, chunk, {scope, sky, block}),
          else: acc
      end)

    start(%{state | light_pending: pending})
  end

  def start(state) do
    cond do
      state.light_pending == %{} or Jobs.running?(state.jobs, :light_frames) or state.light_retry ->
        state

      true ->
        launch(state)
    end
  end

  defp launch(state) do
    selected = state.light_pending |> Enum.sort() |> Enum.take(@batch) |> Map.new()

    versions =
      Map.new(selected, fn {chunk, masks} ->
        {chunk, {Map.get(state.versions, chunk, 0), masks}}
      end)

    images =
      for {chunk, {scope, sky, block}} <- selected,
          image = Blocks.light_image(state.blocks, chunk, {sky, block}),
          do: {chunk, scope, image}

    threshold = Valimc.config(:compression_threshold)

    work = fn ->
      Map.new(images, fn {chunk, scope, image} ->
        {chunk, LightHalo.frame(chunk, image, scope, threshold)}
      end)
    end

    case RegionData.start_job(state, :light_frames, work,
           slots: :chunk_encode,
           data: %{versions: versions}
         ) do
      {:ok, state} -> %{state | light_pending: Map.drop(state.light_pending, Map.keys(selected))}
      {:error, _} -> retry(state)
    end
  end

  def done(state, job, frames) do
    {ready, pending} =
      Enum.reduce(job.versions, {[], state.light_pending}, fn
        {chunk, {version, masks}}, {ready, pending} ->
          if version == Map.get(state.versions, chunk, 0) do
            {[Map.fetch!(frames, chunk) | ready], pending}
          else
            {ready, merge(pending, chunk, masks)}
          end
      end)

    if ready != [],
      do: Valimc.World.publish(RegionData.route_key(state), {:block_batch, Enum.reverse(ready)})

    start(%{state | light_pending: pending})
  end

  def failed(state, job) do
    pending =
      Enum.reduce(job.versions, state.light_pending, fn {chunk, {_, masks}}, pending ->
        merge(pending, chunk, masks)
      end)

    retry(%{state | light_pending: pending})
  end

  defp retry(%{light_retry: true} = state), do: state

  defp retry(state) do
    Process.send_after(self(), {:resource, state.epoch, :light_retry}, 10)
    %{state | light_retry: true}
  end
end
