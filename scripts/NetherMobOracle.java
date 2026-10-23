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
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    return out;
  }

  public static void main(String[] args) throws Exception {
    var level = MobAiOracle.setup();
    if (!args[0].equals("cases")) throw new IllegalArgumentException("usage: NetherMobOracle cases OUT.json");
    var out = cases(level);
    Files.writeString(java.nio.file.Path.of(args[1]), new GsonBuilder().disableHtmlEscaping().serializeNulls().create().toJson(out));
    System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla Nether mob traces (blaze burst, rise, melee, alert; zombified piglin neutral, anger; piglin barter, barter alone).");
  }
}
