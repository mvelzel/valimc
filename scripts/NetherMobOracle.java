import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.phys.Vec3;

/**
 * The Nether's mobs (VMC-043d) ticking with their own goals and brains, in
 * MobAiOracle's probe level and trace format (`MobAiOracle.run`): each tick
 * every mob's position, motion, rotations, random, goals, target, path, hits,
 * sounds, level events and the entities it adds (fireballs, thrown barter
 * items). `cases OUT` writes the traces `check_mob_ai.exs` replays.
 */
public class NetherMobOracle {
  static JsonObject cases(MobAiOracle.Probe level) throws Exception {
    var stone = Blocks.STONE.defaultBlockState();
    var cases = new JsonArray();
    var floor = MobAiOracle.floor(63, 12, stone);
    // A blaze targets a survival player, charges, and fires bursts of three.
    cases.add(MobAiOracle.run(level, "blaze_burst", floor, List.of(new MobAiOracle.Spawn("minecraft:blaze", new Vec3(.5, 64, .5), 0, 31L)),
      List.of(new MobAiOracle.Stand(new Vec3(9.5, 64, 3.5), "survival", null)), List.of(), 320));
    // A player above it: it rises toward its eyes, falling slowly between lifts.
    var ledge = new ArrayList<>(floor);
    ledge.addAll(MobAiOracle.box(6, 64, -2, 9, 69, 2, stone));
    cases.add(MobAiOracle.run(level, "blaze_rise", ledge, List.of(new MobAiOracle.Spawn("minecraft:blaze", new Vec3(.5, 64, .5), 90, 37L)),
      List.of(new MobAiOracle.Stand(new Vec3(7.5, 70, .5), "survival", null)), List.of(), 240));
    // Close by, it burns the player in melee.
    cases.add(MobAiOracle.run(level, "blaze_melee", floor, List.of(new MobAiOracle.Spawn("minecraft:blaze", new Vec3(.5, 64, .5), 0, 43L)),
      List.of(new MobAiOracle.Stand(new Vec3(1.5, 64, 1.5), "survival", null)), List.of(), 80));
    // A creative player is never targeted; hit by a survival one, it alerts the other blaze.
    cases.add(MobAiOracle.run(level, "blaze_alert", floor, List.of(new MobAiOracle.Spawn("minecraft:blaze", new Vec3(.5, 64, .5), 0, 47L),
      new MobAiOracle.Spawn("minecraft:blaze", new Vec3(-4.5, 64, 3.5), 180, 53L)),
      List.of(new MobAiOracle.Stand(new Vec3(3.5, 64, -6.5), "creative", null), new MobAiOracle.Stand(new Vec3(-9.5, 64, -9.5), "survival", null)),
      List.of(new MobAiOracle.Hit(40, 1, 0, 1.0F)), 200));
    // A zombified piglin near a player wanders and never targets it.
    cases.add(MobAiOracle.run(level, "zombified_piglin_neutral", floor, List.of(new MobAiOracle.Spawn("minecraft:zombified_piglin", new Vec3(.5, 64, .5), 0, 59L)),
      List.of(new MobAiOracle.Stand(new Vec3(4.5, 64, 2.5), "survival", null)), List.of(), 300));
    // Hit, it and its kind around it turn on the attacker, angry and faster;
    // the other player is left alone.
    cases.add(MobAiOracle.run(level, "zombified_piglin_anger", floor, List.of(new MobAiOracle.Spawn("minecraft:zombified_piglin", new Vec3(.5, 64, .5), 0, 61L),
      new MobAiOracle.Spawn("minecraft:zombified_piglin", new Vec3(-3.5, 64, 4.5), 90, 67L), new MobAiOracle.Spawn("minecraft:zombified_piglin", new Vec3(6.5, 64, -5.5), 180, 71L)),
      List.of(new MobAiOracle.Stand(new Vec3(2.5, 64, -8.5), "survival", null), new MobAiOracle.Stand(new Vec3(-10.5, 64, 10.5), "survival", null)),
      List.of(new MobAiOracle.Hit(10, 0, 0, 1.0F)), 300));
    // A piglin takes a gold ingot, admires it and throws its barter toward the
    // player it sees, who wears gold and so is left alone.
    cases.add(MobAiOracle.run(level, "piglin_barter", floor, List.of(new MobAiOracle.Spawn("minecraft:piglin", new Vec3(.5, 64, .5), 0, 73L)),
      List.of(new MobAiOracle.Stand(new Vec3(5.5, 64, 4.5), "survival", null, "minecraft:golden_helmet")), List.of(),
      List.of(new MobAiOracle.Drop(new Vec3(3.5, 64, 1.5), "minecraft:gold_ingot", 1)), 260));
    // With no player in sight it throws toward a spot near itself.
    cases.add(MobAiOracle.run(level, "piglin_barter_alone", floor, List.of(new MobAiOracle.Spawn("minecraft:piglin", new Vec3(.5, 64, .5), 0, 79L)),
      List.of(), List.of(), List.of(new MobAiOracle.Drop(new Vec3(-2.5, 64, 3.5), "minecraft:gold_ingot", 1)), 260));
    var sword = Map.<String, Object>of("mainhand", "minecraft:golden_sword");
    // A piglin with a golden sword goes for a player wearing no gold and hits it.
    cases.add(MobAiOracle.run(level, "piglin_attack", floor, List.of(new MobAiOracle.Spawn("minecraft:piglin", new Vec3(.5, 64, .5), 0, 83L, sword)),
      List.of(new MobAiOracle.Stand(new Vec3(6.5, 64, 4.5), "survival", null)), List.of(), 160));
    // Hit by a player in a golden helmet, it and the piglin beside it turn on it.
    cases.add(MobAiOracle.run(level, "piglin_retaliate", floor, List.of(new MobAiOracle.Spawn("minecraft:piglin", new Vec3(-2.5, 64, 3.5), 90, 97L, sword),
      new MobAiOracle.Spawn("minecraft:piglin", new Vec3(.5, 64, .5), 0, 89L, sword)),
      List.of(new MobAiOracle.Stand(new Vec3(4.5, 64, -5.5), "survival", null, "minecraft:golden_helmet")), List.of(new MobAiOracle.Hit(20, 0, 1, 1.0F)), 200));
    // A baby hit runs from the player; the adult, ticking first, takes up
    // its anger.
    cases.add(MobAiOracle.run(level, "piglin_baby_hit", floor, List.of(new MobAiOracle.Spawn("minecraft:piglin", new Vec3(-3.5, 64, 2.5), 0, 103L, sword),
      new MobAiOracle.Spawn("minecraft:piglin", new Vec3(.5, 64, .5), 0, 101L, Map.of("baby", true))),
      List.of(new MobAiOracle.Stand(new Vec3(3.5, 64, -3.5), "survival", null, "minecraft:golden_helmet")), List.of(new MobAiOracle.Hit(30, 0, 1, 1.0F)), 200));
    // A zombified piglin close by: it backs away.
    cases.add(MobAiOracle.run(level, "piglin_avoid", floor, List.of(new MobAiOracle.Spawn("minecraft:piglin", new Vec3(.5, 64, .5), 0, 107L, sword),
      new MobAiOracle.Spawn("minecraft:zombified_piglin", new Vec3(3.5, 64, 1.5), 270, 109L)),
      List.of(), List.of(), 200));
    // Soul fire four blocks off: it walks away from it.
    var fire = new ArrayList<>(floor);
    fire.add(new MobAiOracle.Block(3, 64, 1, Blocks.SOUL_FIRE.defaultBlockState()));
    fire.add(new MobAiOracle.Block(3, 63, 1, Blocks.SOUL_SAND.defaultBlockState()));
    cases.add(MobAiOracle.run(level, "piglin_repellent", fire, List.of(new MobAiOracle.Spawn("minecraft:piglin", new Vec3(.5, 64, .5), 0, 113L, sword)),
      List.of(), List.of(), 160));
    // A ghast alone drifts to random places and faces where it drifts.
    cases.add(MobAiOracle.run(level, "ghast_float", floor, List.of(new MobAiOracle.Spawn("minecraft:ghast", new Vec3(.5, 70, .5), 0, 127L)),
      List.of(), List.of(), 300));
    // A player on a pillar at its height: it turns to it, charges and shoots,
    // then rests.
    var pillar = new ArrayList<>(floor);
    pillar.addAll(MobAiOracle.box(9, 64, 9, 10, 69, 10, stone));
    cases.add(MobAiOracle.run(level, "ghast_attack", pillar, List.of(new MobAiOracle.Spawn("minecraft:ghast", new Vec3(-6.5, 70, -4.5), 0, 131L)),
      List.of(new MobAiOracle.Stand(new Vec3(9.5, 70, 9.5), "survival", null)), List.of(), 200));
    // Walled in: a place behind a wall stops its drift.
    var cage = new ArrayList<>(floor);
    cage.addAll(MobAiOracle.box(-4, 64, -4, 4, 64, 4, stone));
    for (int y = 65; y < 76; y++) {
      cage.addAll(MobAiOracle.box(-4, y, -4, 4, y, -4, stone)); cage.addAll(MobAiOracle.box(-4, y, 4, 4, y, 4, stone));
      cage.addAll(MobAiOracle.box(-4, y, -3, -4, y, 3, stone)); cage.addAll(MobAiOracle.box(4, y, -3, 4, y, 3, stone));
    }
    cases.add(MobAiOracle.run(level, "ghast_cage", cage, List.of(new MobAiOracle.Spawn("minecraft:ghast", new Vec3(.5, 67, .5), 0, 137L)),
      List.of(), List.of(), 200));
    // A magma cube alone hops random ways, squishing as it lands.
    cases.add(MobAiOracle.run(level, "magma_cube_hop", floor, List.of(new MobAiOracle.Spawn("minecraft:magma_cube", new Vec3(.5, 64, .5), 0, 139L,
      Map.<String, Object>of("size", 2))), List.of(), List.of(), 400));
    // A survival player near a big one: it hops at it three times as often
    // and hurts it at a touch; hit, it groans.
    cases.add(MobAiOracle.run(level, "magma_cube_attack", floor, List.of(new MobAiOracle.Spawn("minecraft:magma_cube", new Vec3(.5, 64, .5), 0, 149L,
      Map.<String, Object>of("size", 4))), List.of(new MobAiOracle.Stand(new Vec3(5.5, 64, 3.5), "survival", null)),
      List.of(new MobAiOracle.Hit(150, 0, 0, 1.0F)), 300));
    // The smallest in a lava pool leaps out of it.
    var pool = new ArrayList<>(floor);
    pool.addAll(MobAiOracle.box(-3, 64, -3, 3, 64, 3, stone));
    pool.addAll(MobAiOracle.box(-2, 64, -2, 2, 64, 2, Blocks.LAVA.defaultBlockState()));
    cases.add(MobAiOracle.run(level, "magma_cube_lava", pool, List.of(new MobAiOracle.Spawn("minecraft:magma_cube", new Vec3(.5, 64, .5), 0, 151L,
      Map.<String, Object>of("size", 1))), List.of(), List.of(), 200));
    // A hoglin goes for a survival player, hits it every two seconds and throws it.
    cases.add(MobAiOracle.run(level, "hoglin_attack", floor, List.of(new MobAiOracle.Spawn("minecraft:hoglin", new Vec3(.5, 64, .5), 0, 157L)),
      List.of(new MobAiOracle.Stand(new Vec3(6.5, 64, 4.5), "survival", null)), List.of(), 200));
    // A warped fungus near it: pacified, it walks away from it and leaves the player be.
    var fungus = new ArrayList<>(floor);
    fungus.add(new MobAiOracle.Block(2, 64, 1, Blocks.WARPED_FUNGUS.defaultBlockState()));
    fungus.add(new MobAiOracle.Block(2, 63, 1, Blocks.WARPED_NYLIUM.defaultBlockState()));
    cases.add(MobAiOracle.run(level, "hoglin_repellent", fungus, List.of(new MobAiOracle.Spawn("minecraft:hoglin", new Vec3(.5, 64, .5), 0, 163L)),
      List.of(new MobAiOracle.Stand(new Vec3(-6.5, 64, 4.5), "survival", null)), List.of(), 200));
    // A baby with an adult: both go for the player; hit, the baby flees it.
    cases.add(MobAiOracle.run(level, "hoglin_baby_hit", floor, List.of(new MobAiOracle.Spawn("minecraft:hoglin", new Vec3(-3.5, 64, 2.5), 0, 167L),
      new MobAiOracle.Spawn("minecraft:hoglin", new Vec3(.5, 64, .5), 0, 173L, Map.of("baby", true))),
      List.of(new MobAiOracle.Stand(new Vec3(5.5, 64, -4.5), "survival", null)), List.of(new MobAiOracle.Hit(20, 0, 1, 1.0F)), 200));
    // Alone, it wanders and looks about.
    cases.add(MobAiOracle.run(level, "hoglin_idle", floor, List.of(new MobAiOracle.Spawn("minecraft:hoglin", new Vec3(.5, 64, .5), 90, 179L)),
      List.of(), List.of(), 300));
    // A wither skeleton with its stone sword chases a survival player and withers it.
    var witherSword = Map.<String, Object>of("mainhand", "minecraft:stone_sword");
    cases.add(MobAiOracle.run(level, "wither_skeleton_attack", floor, List.of(new MobAiOracle.Spawn("minecraft:wither_skeleton", new Vec3(.5, 64, .5), 0, 181L, witherSword)),
      List.of(new MobAiOracle.Stand(new Vec3(7.5, 64, 3.5), "survival", null)), List.of(), 160));
    // A strider on a lava pool walks about on it.
    var pool9 = new ArrayList<>(floor);
    pool9.addAll(MobAiOracle.box(-4, 63, -4, 4, 63, 4, Blocks.LAVA.defaultBlockState()));
    pool9.addAll(MobAiOracle.box(-5, 64, -5, 5, 64, 5, stone));
    pool9.addAll(MobAiOracle.box(-4, 64, -4, 4, 64, 4, Blocks.AIR.defaultBlockState()));
    cases.add(MobAiOracle.run(level, "strider_lava", pool9, List.of(new MobAiOracle.Spawn("minecraft:strider", new Vec3(.5, 63.5, .5), 0, 191L)),
      List.of(), List.of(), 300));
    // On stone it shivers and heads for the lava nearby.
    var side = new ArrayList<>(floor);
    side.addAll(MobAiOracle.box(4, 63, -2, 8, 63, 2, Blocks.LAVA.defaultBlockState()));
    cases.add(MobAiOracle.run(level, "strider_to_lava", side, List.of(new MobAiOracle.Spawn("minecraft:strider", new Vec3(-2.5, 64, .5), 0, 193L)),
      List.of(), List.of(), 300));
    // A player holding warped fungus tempts it.
    cases.add(MobAiOracle.run(level, "strider_tempt", floor, List.of(new MobAiOracle.Spawn("minecraft:strider", new Vec3(.5, 64, .5), 0, 197L)),
      List.of(new MobAiOracle.Stand(new Vec3(5.5, 64, 3.5), "survival", "minecraft:warped_fungus")), List.of(), 200));
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    return out;
  }

  public static void main(String[] args) throws Exception {
    var level = MobAiOracle.setup();
    if (!args[0].equals("cases")) throw new IllegalArgumentException("usage: NetherMobOracle cases OUT.json");
    var out = cases(level);
    Files.writeString(java.nio.file.Path.of(args[1]), new GsonBuilder().disableHtmlEscaping().serializeNulls().create().toJson(out));
    System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla Nether mob traces (blaze burst, rise, melee, alert; zombified piglin neutral, anger; piglin barter, barter alone, attack, retaliate, baby hit, avoid, repellent; ghast float, attack, cage; magma cube hop, attack, lava; hoglin attack, repellent, baby hit, idle; wither skeleton attack; strider lava, to lava, tempt).");
  }
}
