import com.google.gson.*;
import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.exceptions.CommandSyntaxException;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import java.util.function.Supplier;
import net.minecraft.ChatFormatting;
import net.minecraft.SharedConstants;
import net.minecraft.commands.CommandSource;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.core.RegistryAccess;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.network.chat.ComponentUtils;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.commands.WorldBorderCommand;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.permissions.LevelBasedPermissionSet;
import net.minecraft.util.Mth;
import net.minecraft.world.entity.EntityTypes;
import net.minecraft.world.level.border.BorderChangeListener;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec2;
import net.minecraft.world.phys.Vec3;

/**
 * World border parity (VMC-027b/c) against vanilla's own `WorldBorder` and
 * `WorldBorderCommand`.
 *
 * `kernel OUT`: scripted sequences of border changes and game ticks on an
 * actual `WorldBorder` with a listener that encodes the packets vanilla's
 * player list broadcasts for each change. After every step: size, lerp
 * target and remaining ticks, status, bounds, the saved settings, the
 * initialize packet, and for sample points the containment, distance, the
 * player box containment and the damage `LivingEntity.baseTick` deals
 * outside (its formula over the border's own queries). `reload` saves and
 * loads the border as vanilla's saved data does (`Settings`, then
 * `applyInitialSettings` at the current game time).
 *
 * `commands OUT`: sequences of `/worldborder` inputs run through vanilla's
 * command on a probe level holding the border; per input the feedback as
 * system chat packets (failures red, as the command source reports them),
 * whether it is broadcast to operators, the result, and the border after.
 */
public class WorldBorderOracle {
  static final HexFormat HEX = HexFormat.of();
  static final List<String> events = new ArrayList<>();
  static WorldBorder current;
  static long gameTime;

  static class ProbeLevel extends ServerLevel {
    ProbeLevel() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    @Override public WorldBorder getWorldBorder() { return current; }
    @Override public long getGameTime() { return gameTime; }
  }

  static class Capture extends CommandSourceStack {
    final List<JsonObject> messages;
    Capture(ServerLevel level, List<JsonObject> messages) {
      super(CommandSource.NULL, new Vec3(10.5, 64, -3.25), Vec2.ZERO, level, LevelBasedPermissionSet.OWNER, Component.literal("Oracle"), null);
      this.messages = messages;
    }
    @Override public void sendSuccess(Supplier<Component> message, boolean allowLogging) {
      var m = new JsonObject();
      m.addProperty("packet", chat(message.get()));
      m.addProperty("broadcast", allowLogging);
      messages.add(m);
    }
    @Override public void sendFailure(Component message) {
      var m = new JsonObject();
      m.addProperty("packet", chat(Component.empty().append(message).withStyle(ChatFormatting.RED)));
      m.addProperty("broadcast", false);
      messages.add(m);
    }
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  static String wire(Packet<?> packet) {
    var buffer = new RegistryFriendlyByteBuf(Unpooled.buffer(), RegistryAccess.EMPTY);
    try {
      GameProtocols.CLIENTBOUND_TEMPLATE.bind(b -> new RegistryFriendlyByteBuf(b, RegistryAccess.EMPTY)).codec().encode(buffer, (Packet) packet);
      var bytes = new byte[buffer.readableBytes()];
      buffer.readBytes(bytes);
      return HEX.formatHex(bytes);
    } finally {
      buffer.release();
    }
  }

  static String chat(Component component) { return wire(new ClientboundSystemChatPacket(component, false)); }
  static String bits(double value) { return HEX.toHexDigits(Double.doubleToRawLongBits(value)); }

  static void listen(WorldBorder border) {
    border.addListener(new BorderChangeListener() {
      public void onSetSize(WorldBorder b, double size) { events.add(wire(new ClientboundSetBorderSizePacket(b))); }
      public void onLerpSize(WorldBorder b, double from, double to, long ticks, long time) { events.add(wire(new ClientboundSetBorderLerpSizePacket(b))); }
      public void onSetCenter(WorldBorder b, double x, double z) { events.add(wire(new ClientboundSetBorderCenterPacket(b))); }
      public void onSetWarningTime(WorldBorder b, int time) { events.add(wire(new ClientboundSetBorderWarningDelayPacket(b))); }
      public void onSetWarningBlocks(WorldBorder b, int blocks) { events.add(wire(new ClientboundSetBorderWarningDistancePacket(b))); }
      public void onSetDamagePerBlock(WorldBorder b, double damage) {}
      public void onSetSafeZone(WorldBorder b, double safe) {}
    });
  }

  static WorldBorder fresh() {
    var border = new WorldBorder();
    border.applyInitialSettings(gameTime);
    border.setAbsoluteMaxSize(29999984);
    listen(border);
    return border;
  }

  static JsonObject state(WorldBorder b) {
    var s = new JsonObject();
    s.addProperty("size", bits(b.getSize()));
    s.addProperty("target", bits(b.getLerpTarget()));
    s.addProperty("lerp_time", b.getLerpTime());
    s.addProperty("status", b.getStatus().name().toLowerCase(Locale.ROOT));
    var bounds = new JsonArray();
    for (double v : new double[]{b.getMinX(), b.getMinZ(), b.getMaxX(), b.getMaxZ()}) bounds.add(bits(v));
    s.add("bounds", bounds);
    var settings = new WorldBorder.Settings(b);
    var saved = new JsonArray();
    saved.add(bits(settings.centerX())); saved.add(bits(settings.centerZ()));
    saved.add(bits(settings.damagePerBlock())); saved.add(bits(settings.safeZone()));
    saved.add(settings.warningBlocks()); saved.add(settings.warningTime());
    saved.add(bits(settings.size())); saved.add(settings.lerpTime()); saved.add(bits(settings.lerpTarget()));
    s.add("settings", saved);
    s.addProperty("initialize", wire(new ClientboundInitializeBorderPacket(b)));
    var points = new JsonArray();
    double x0 = b.getMinX(), z0 = b.getMinZ(), x1 = b.getMaxX(), z1 = b.getMaxZ();
    double cx = b.getCenterX(), cz = b.getCenterZ();
    var dims = EntityTypes.PLAYER.getDimensions();
    for (double[] p : new double[][]{{cx, cz}, {x0, cz}, {x0 + 0.3, cz}, {x0 + 0.30000001192092896, cz}, {x0 - 0.3, cz},
        {x1, cz}, {x1 - 0.3, cz}, {x1 - 0.30000001192092896, cz}, {x1 - 0.31, cz}, {cx, z1 + 2}, {cx, z0 - 5.5},
        {x0 - 6, z0 - 6}, {x1 + 20, cz}, {cx, z1 + 1000}, {x0 - 1e6, cz}}) {
      var box = dims.makeBoundingBox(p[0], 64, p[1]);
      var r = new JsonObject();
      r.addProperty("x", bits(p[0])); r.addProperty("z", bits(p[1]));
      r.addProperty("inside", b.isWithinBounds(p[0], p[1]));
      r.addProperty("box_inside", b.isWithinBounds(box));
      r.addProperty("distance", bits(b.getDistanceToBorder(p[0], p[1])));
      float damage = 0.0F;
      if (!b.isWithinBounds(box)) {
        double dist = b.getDistanceToBorder(p[0], p[1]) + b.getSafeZone();
        if (dist < 0.0 && b.getDamagePerBlock() > 0.0) damage = Math.max(1, Mth.floor(-dist * b.getDamagePerBlock()));
      }
      r.addProperty("damage", (double) damage);
      points.add(r);
    }
    s.add("points", points);
    return s;
  }

  // ---- kernel ----

  static final String[][] SCRIPTS = {
    {"tick 2"},
    {"size 10", "tick 1", "center 0.5 -0.5", "tick 1"},
    {"lerp 100 20 40", "tick 1", "tick 1", "tick 10", "tick 30"},
    {"lerp 20 100 7", "tick 3", "reload", "tick 5"},
    {"lerp 59999968 1 1000", "tick 1", "size 64", "tick 2"},
    {"center 1000.25 -2000.75", "lerp 16 8 3", "tick 1", "center -5 5", "tick 4"},
    {"lerp 10 10 20", "tick 2"},
    {"damage 0.5", "safe 2", "size 8", "tick 1", "damage 0", "tick 1", "damage 1e9", "safe 0", "tick 1"},
    {"warning_time 20", "warning_blocks 0", "warning_time 300", "warning_blocks 1000", "tick 1"},
    {"absolute 32", "size 100", "tick 1", "center 29999980 -29999980", "tick 1"},
    {"lerp 1 3 1", "tick 1", "tick 1"},
    {"lerp 1000 1 100", "tick 50", "reload", "tick 49", "tick 1", "tick 1"},
    {"center -29999984 29999984", "size 59999968", "tick 1"},
    {"size 1", "center 0.1 0.2", "safe 0.5", "damage 3.25", "tick 1"},
  };

  static void kernel(String out) throws Exception {
    var all = new JsonArray();
    for (var script : SCRIPTS) {
      gameTime = 5000;
      events.clear();
      current = fresh();
      var steps = new JsonArray();
      var initial = new JsonObject();
      initial.addProperty("op", "start");
      initial.addProperty("game_time", gameTime);
      initial.add("state", state(current));
      steps.add(initial);
      for (var line : script) {
        var w = line.split(" ");
        events.clear();
        int repeat = w[0].equals("tick") ? Integer.parseInt(w[1]) : 1;
        for (int i = 0; i < repeat; i++) {
          switch (w[0]) {
            case "tick" -> { current.tick(); gameTime++; }
            case "size" -> current.setSize(Double.parseDouble(w[1]));
            case "lerp" -> current.lerpSizeBetween(Double.parseDouble(w[1]), Double.parseDouble(w[2]), Long.parseLong(w[3]), gameTime);
            case "center" -> current.setCenter(Double.parseDouble(w[1]), Double.parseDouble(w[2]));
            case "damage" -> current.setDamagePerBlock(Double.parseDouble(w[1]));
            case "safe" -> current.setSafeZone(Double.parseDouble(w[1]));
            case "warning_time" -> current.setWarningTime(Integer.parseInt(w[1]));
            case "warning_blocks" -> current.setWarningBlocks(Integer.parseInt(w[1]));
            case "absolute" -> current.setAbsoluteMaxSize(Integer.parseInt(w[1]));
            case "reload" -> {
              int absolute = current.getAbsoluteMaxSize();
              current = new WorldBorder(new WorldBorder.Settings(current));
              current.applyInitialSettings(gameTime);
              current.setAbsoluteMaxSize(absolute);
              listen(current);
            }
            default -> throw new AssertionError(line);
          }
        }
        var step = new JsonObject();
        step.addProperty("op", line);
        step.addProperty("game_time", gameTime);
        step.add("events", new Gson().toJsonTree(events));
        step.add("state", state(current));
        steps.add(step);
      }
      all.add(steps);
    }
    Files.writeString(Path.of(out), new Gson().toJson(all));
    System.out.println("PASS: " + SCRIPTS.length + " actual world border scripts: ticks, moving extents, bounds, saved settings, listener packets, damage outside.");
  }

  // ---- commands ----

  static final String[][] COMMANDS = {
    {"worldborder get", "worldborder set 100", "worldborder get", "worldborder set 100", "worldborder set 0.5",
     "worldborder set 59999968", "worldborder set 1", "worldborder get"},
    {"worldborder set 1000 10s", "#tick 5", "worldborder get", "worldborder add -200 100", "#tick 3",
     "worldborder add 50", "worldborder set 50 1", "#tick 1", "worldborder add 25 1d"},
    {"worldborder center 1 2", "worldborder center 1 2", "worldborder center 1.5 2.5", "worldborder center ~ ~",
     "worldborder center ~1 ~-1", "worldborder center 0.1 -0.1", "worldborder center 29999984 0",
     "worldborder center 30000000 0", "worldborder center -29999984.5 3"},
    {"worldborder damage amount 0.2", "worldborder damage amount 0.5", "worldborder damage amount 0.5",
     "worldborder damage amount 12345.678", "worldborder damage buffer 5", "worldborder damage buffer 2.25",
     "worldborder damage buffer 0", "worldborder damage buffer 1.005", "worldborder damage amount 0"},
    {"worldborder warning time 15", "worldborder warning time 300", "worldborder warning time 1s",
     "worldborder warning time 0", "worldborder warning time 1d", "worldborder warning distance 5",
     "worldborder warning distance 0", "worldborder warning distance 2147483647"},
    {"worldborder set 10", "worldborder add 0.05", "worldborder add -9.5", "worldborder add -0.6",
     "worldborder set 2 0", "worldborder set 3 3", "#tick 1", "worldborder get", "worldborder set 1.25 7t", "#tick 2", "worldborder get"},
  };

  static void commands(String out) throws Exception {
    var u = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    u.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) u.get(null);
    var level = (ServerLevel) unsafe.allocateInstance(ProbeLevel.class);
    var dispatcher = new CommandDispatcher<CommandSourceStack>();
    WorldBorderCommand.register(dispatcher);
    var all = new JsonArray();
    for (var sequence : COMMANDS) {
      gameTime = 5000;
      events.clear();
      current = fresh();
      var rows = new JsonArray();
      for (var input : sequence) {
        var row = new JsonObject();
        row.addProperty("input", input);
        events.clear();
        if (input.startsWith("#tick ")) {
          for (int i = Integer.parseInt(input.substring(6)); i > 0; i--) { current.tick(); gameTime++; }
        } else {
          var messages = new ArrayList<JsonObject>();
          var source = new Capture(level, messages);
          try {
            row.addProperty("result", dispatcher.execute(input, source));
          } catch (CommandSyntaxException e) {
            // Execution failures only: every input parses.
            if (e.getCursor() >= 0) throw new AssertionError("parse failure: " + input);
            source.sendFailure(ComponentUtils.fromMessage(e.getRawMessage()));
          }
          row.add("messages", new Gson().toJsonTree(messages));
        }
        row.addProperty("game_time", gameTime);
        row.add("events", new Gson().toJsonTree(events));
        row.add("state", state(current));
        rows.add(row);
      }
      all.add(rows);
    }
    Files.writeString(Path.of(out), new Gson().toJson(all));
    System.out.println("PASS: " + COMMANDS.length + " actual /worldborder sequences: feedback packets, broadcast flags, results, border state.");
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    switch (args[0]) {
      case "kernel" -> kernel(args[1]);
      case "commands" -> commands(args[1]);
      default -> throw new AssertionError(args[0]);
    }
  }
}
