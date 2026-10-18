alias Valimc.{ChestOpening, World}
alias Valimc.World.{Containers, Region, Store}
[output] = System.argv()
dataset = Path.join(System.tmp_dir!(), "valimc-viewer-bench-#{System.os_time(:nanosecond)}")
Application.put_env(:valimc, :world_path, dataset)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :item_simulation, false)
{:ok, _} = Application.ensure_all_started(:valimc)
subscribed = Code.ensure_loaded?(Valimc.World.ContainerViewers)
block = hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])

results =
  for count <- [128, 512] do
    key = {900 + count, 900}
    span = Valimc.config(:region_size) * 16
    position = {elem(key, 0) * span + 40, 64, elem(key, 1) * span + 40}
    {x, _, z} = position
    {:ok, containers, entry} = Containers.create(%Containers{}, key, position, 3)
    {:ok, bytes} = Containers.encode(key, containers)
    path = Store.container_path(dataset, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    {:ok, owner} = World.owner(key)
    :ok = World.set_block(position, block)
    parent = self()

    clients =
      for _ <- 1..count do
        pid =
          spawn(fn ->
            loop = fn loop ->
              receive do
                {:event, {:table_admitted, ref, _, decision}} ->
                  if decision != :valid and not match?({:chest, _, _}, decision),
                    do: exit({:invalid_view, decision})

                  send(parent, {:observed, self(), ref})
                  loop.(loop)

                :stop ->
                  :ok
              end
            end

            loop.(loop)
          end)

        {pid, make_ref()}
      end

    grant = fn kind, view_ref ->
      %{
        kind: kind,
        mode: :survival,
        eye: {x + 0.5, 65.62, z - 2.5},
        expires: System.monotonic_time(:millisecond) + 250,
        hand: :main,
        secondary: false,
        main: true,
        off: false,
        menu: :chest,
        view_ref: view_ref,
        revision: entry.revision
      }
    end

    await = fn pid, ref ->
      receive do
        {:observed, ^pid, ^ref} -> :ok
      after
        1000 -> raise "Viewer query timed out"
      end
    end

    # Both versions establish the same initial private storage snapshot before measurement.
    for {pid, ref} <- clients do
      :ok =
        Region.request_table(
          owner,
          pid,
          ref,
          position,
          grant.(if(subscribed, do: :subscribe, else: :refresh), ref)
        )

      await.(pid, ref)
    end

    # An identical warm round precedes each timed sample.
    cycles = 40

    round = fn ->
      for {pid, view_ref} <- clients do
        {:ok, ^owner} = World.existing_owner(key)

        true =
          ChestOpening.authorize(
            block,
            entry,
            0,
            position,
            grant.(:check, view_ref),
            System.monotonic_time(:millisecond)
          ) == :valid

        if not subscribed do
          ref = make_ref()
          :ok = Region.request_table(owner, pid, ref, position, grant.(:check, view_ref))
          await.(pid, ref)
        end
      end
    end

    round.()

    samples =
      for _ <- 1..3 do
        {:reductions, before} = Process.info(elem(owner, 0), :reductions)
        {elapsed, _} = :timer.tc(fn -> for _ <- 1..cycles, do: round.() end)
        {:reductions, after_count} = Process.info(elem(owner, 0), :reductions)

        %{
          elapsed_us: elapsed,
          owner_reductions: after_count - before,
          local_checks: count * cycles,
          owner_queries: if(subscribed, do: 0, else: count * cycles)
        }
      end

    # Normal close/disconnect is outside the measured interval.
    for {pid, _} <- clients, do: send(pid, :stop)
    %{viewers: count, samples: samples}
  end

File.write!(
  output,
  JSON.encode!(%{
    version: "26.3",
    protocol: 777,
    subscribed: subscribed,
    workload: "single-owner idle-view component; accelerated 40 checks/viewer, three samples",
    limits:
      "No TCP, world simulation, moving players, writes, CPU capacity or fastest-server claim; local checks conservatively include native grant validation in both versions.",
    results: results
  })
)

Application.stop(:valimc)
File.rm_rf!(dataset)
