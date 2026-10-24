defmodule Valimc.CombatTest do
  @moduledoc "Melee (VMC-037n): the one hurt path for mobs, their death drops, and the attack rules."
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Combat, Store}
  alias Valimc.Living.{Damage, DamageSource, Melee}
  alias Valimc.Protocol.{ItemStack, ItemTypes, Packets}
  alias Valimc.TestScope
  alias Valimc.World.Region

  @player %{
    uuid: <<9::128>>,
    entity_id: 900,
    player: true,
    type: "minecraft:player",
    mainhand: nil
  }

  defp zombie(position \\ {1.5, 64.0, 2.5}, type \\ "minecraft:zombie") do
    {:ok, body} = Body.new(type)
    record = Store.body_record(body, <<7::128>>, position)
    {:ok, store, {_, id, _}} = Store.create_record(Store.new(), {0, 0}, record)
    {store, id}
  end

  defp hit(amount, attacker \\ @player),
    do: %{
      source: DamageSource.new(:player_attack),
      amount: amount,
      attacker: attacker,
      direct: attacker,
      position: {0.5, 64.0, 2.5}
    }

  defp binary({id, payload}), do: {id, IO.iodata_to_binary(payload)}

  test "a bullet accepts even a zero hit, returns a nonliving attack outcome and removes once" do
    {store, id} = zombie({1.5, 64.0, 2.5}, "minecraft:shulker_bullet")
    {:ok, next, outcome} = Combat.hurt(store, id, hit(0.0))
    assert outcome.hurt
    assert outcome.previous == 0.0 and outcome.health == 0.0
    assert length(outcome.feedback) == 2
    refute Map.has_key?(next.entries, id)
    assert {:error, :missing_entity} = Combat.hurt(next, id, hit(0.0))
  end

  test "a hit goes through the zombie's armor, knocks it away and starts its cooldown" do
    {store, id} = zombie()
    {:ok, store, outcome} = Combat.hurt(store, id, hit(7.0))
    # A zombie's natural armor is 2.
    {:ok, expected} = Damage.armor_absorb(7.0, 2.0, 0.0)
    assert outcome.hurt and outcome.full and not outcome.died
    assert outcome.health == Valimc.Data.Float32.round(20.0 - expected)

    entry = store.entries[id]
    [{_, damage}, {_, _sound}] = entry.events
    assert damage == binary(Packets.damage_event(id, :player_attack, 900, 900))
    # Away from the attacker on its west: +x, not lifted off the ground it is not on.
    {vx, vy, vz} = entry.body.velocity
    assert vx > 0.39 and vy == 0.0 and abs(vz) < 1.0e-9
    assert entry.body.mob.hurt_by_player == <<9::128>> and entry.body.mob.player_memory == 100

    # Within the cooldown a weaker hit does nothing; a stronger one deals the difference.
    assert {:ok, ^store, %{hurt: false}} = Combat.hurt(store, id, hit(5.0))
    {:ok, store, outcome} = Combat.hurt(store, id, hit(9.0))
    assert outcome.hurt and not outcome.full and length(store.entries[id].events) == 2
  end

  test "a mob whose sounds are not modelled yet is hurt without a sound" do
    {store, id} = zombie({1.5, 64.0, 2.5}, "minecraft:sniffer")
    {:ok, store, outcome} = Combat.hurt(store, id, hit(3.0))
    assert outcome.hurt and outcome.full
    assert [{_, damage}] = store.entries[id].events
    assert damage == binary(Packets.damage_event(id, :player_attack, 900, 900))
  end

  test "a player's kill dies with its loot table and experience; another kill gives none" do
    {store, id} = zombie()
    {:ok, store, outcome} = Combat.hurt(store, id, hit(40.0))
    assert outcome.died and not Body.alive?(store.entries[id].body)
    # The death waits on the mob for its owner (`Store.take_deaths/1`).
    {taken, [{death, {1.5, 64.0, 2.5}}]} = Store.take_deaths(store)
    assert taken.entries[id].body.mob.death == nil

    assert %{
             loot_table: "minecraft:entities/zombie",
             loot: %{killed_by_player: true, attacker: nil},
             experience: 5
           } = death

    assert List.last(store.entries[id].events) |> elem(1) ==
             binary(Valimc.Protocol.EntityPackets.entity_event(id, 3))

    {store, id} = zombie()
    {:ok, store, _} = Combat.hurt(store, id, hit(40.0, nil))
    {_, [{death, _}]} = Store.take_deaths(store)
    assert %{loot: %{killed_by_player: false, attacker: :none}, experience: 0} = death
  end

  test "attack strength, criticals and sweeps follow vanilla's rules" do
    # A sword (attack speed 1.6): 12.5 ticks to full strength.
    assert Melee.strength(12, 1.6) == 1.0
    assert Melee.strength(0, 1.6) == Valimc.Data.Float32.round(0.5 / 12.5)

    {:ok, full} =
      Melee.attack(%{
        damage: 7.0,
        enchanted: 7.0,
        strength: 1.0,
        sprinting: false,
        critical: true,
        sweep: true
      })

    assert full.critical and full.damage == 10.5 and not full.sweep

    {:ok, weak} =
      Melee.attack(%{
        damage: 7.0,
        enchanted: 8.5,
        strength: 0.5,
        sprinting: true,
        critical: true,
        sweep: true
      })

    refute weak.critical or weak.sweep or weak.sprint_knockback
    # (0.2 + 0.25 * 0.8) * 7 plus half the enchantment bonus.
    assert_in_delta weak.damage, 2.8 + 0.75, 1.0e-6
  end

  describe "an owner" do
    setup do
      nonce = System.unique_integer([:positive])
      key = {31_000 + rem(nonce, 3_000) * 3, 905}
      base = Path.join(System.tmp_dir!(), "valimc-combat-#{nonce}")
      TestScope.isolate(TestScope.neighborhood(key), world_path: base)
      File.mkdir_p!(base)
      Valimc.TestDisk.write(base, key, :items, %{records: []})
      {:ok, owner} = Valimc.TestWorld.item_owner(key)

      on_exit(fn ->
        for {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
        File.rm_rf(base)
      end)

      %{key: key, owner: owner}
    end

    test "drops a zombie's loot and a player kill's experience where it dies", ctx do
      {rx, rz} = ctx.key
      position = {rx * 128 + 20.5, 64.0, rz * 128 + 20.5}
      {:ok, body} = Body.new("minecraft:zombie")
      :ok = Region.drop_items(ctx.owner, [Store.body_record(body, <<3::128>>, position)])

      sword = %ItemStack{item_id: ItemTypes.id("diamond_sword"), count: 1}
      attacker = %{@player | mainhand: sword}
      assert {:ok, %{died: true}} = Region.hurt_entity(ctx.owner, <<3::128>>, hit(40.0, attacker))
      store = Valimc.TestRegion.section(ctx.owner).entities.store
      orbs = for %{kind: :orb} = e <- Map.values(store.entries), do: e.value * e.count
      assert Enum.sum(orbs) == 5

      for %{kind: :item, stack: stack} <- Map.values(store.entries),
          do: assert(ItemTypes.item(stack.item_id)["name"] == "minecraft:rotten_flesh")

      # A dead mob takes no more hits.
      assert {:ok, %{hurt: false}} = Region.hurt_entity(ctx.owner, <<3::128>>, hit(5.0))
    end
  end
end
