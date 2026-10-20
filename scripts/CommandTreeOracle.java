import com.google.gson.*;
import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.ParseResults;
import com.mojang.brigadier.arguments.ArgumentType;
import com.mojang.brigadier.builder.ArgumentBuilder;
import com.mojang.brigadier.builder.LiteralArgumentBuilder;
import com.mojang.brigadier.builder.RequiredArgumentBuilder;
import com.mojang.brigadier.context.CommandContext;
import com.mojang.brigadier.context.CommandContextBuilder;
import com.mojang.brigadier.tree.*;
import io.netty.buffer.Unpooled;
import java.lang.reflect.Method;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.SharedConstants;
import net.minecraft.commands.*;
import net.minecraft.commands.synchronization.*;
import net.minecraft.core.HolderLookup;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.network.chat.ComponentSerialization;
import net.minecraft.network.protocol.game.ClientboundCommandsPacket;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.server.permissions.LevelBasedPermissionSet;
import net.minecraft.server.permissions.PermissionSet;
import net.minecraft.world.flag.FeatureFlags;

/**
 * Vanilla command facts and parse parity (VMC-053).
 *
 * `tree OUT` writes the dedicated server's Brigadier tree in dispatcher order:
 * literal/argument nodes, executable flags, redirects (as paths), the lowest
 * permission level that may use each node, the packet's restricted flag, argument
 * parser registry IDs with their JSON and network properties, and suggestion IDs.
 *
 * `cases OUT` writes command inputs at permission levels 0 and 4. ValiMC parses
 * them (`check_commands.exs`) and records its graph per level and the system chat
 * components it would send. `verify GRAPHS RESULTS` decodes ValiMC's graphs with
 * Mojang's packet codec and requires each to be vanilla's usable tree pruned to
 * ValiMC's commands, then requires every parse outcome to equal vanilla's
 * `Commands.finishParsing` messages (decoded components) or executable path.
 */
public class CommandTreeOracle {
  static CommandDispatcher<CommandSourceStack> dispatcher;
  static HolderLookup.Provider lookup;

  public static void main(String[] args) throws Exception {
    initialize();
    switch (args[0]) {
      case "tree" -> write(args[1], tree());
      case "facts" -> write(args[1], facts());
      case "cases" -> write(args[1], cases());
      case "verify" -> verify(Path.of(args[1]), Path.of(args[2]));
      default -> throw new IllegalArgumentException(args[0]);
    }
  }

  static void initialize() throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var initial = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(initial).forEach(p -> p.apply());
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA,
        List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var access = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, access);
      var statics = net.minecraft.tags.TagLoader.buildUpdatedLookups(access, pending);
      var staticKeys = statics.stream().map(r -> r.key()).collect(Collectors.toSet());
      var base = HolderLookup.Provider.create(Stream.concat(
          initial.listRegistries().filter(r -> !staticKeys.contains(r.key())), statics.stream()));
      var loaded = RegistryDataLoader.load(resources, base.listRegistries().toList(),
          RegistryDataLoader.RELOADABLE_REGISTRIES, Runnable::run).join();
      var keys = loaded.listRegistryKeys().collect(Collectors.toSet());
      lookup = HolderLookup.Provider.create(Stream.concat(
          base.listRegistries().filter(r -> !keys.contains(r.key())), loaded.listRegistries()));
      for (var tags : pending) tags.apply();
    }
    var context = CommandBuildContext.simple(lookup, FeatureFlags.DEFAULT_FLAGS);
    dispatcher = new Commands(Commands.CommandSelection.DEDICATED, context).getDispatcher();
  }

  static void write(String path, JsonElement json) throws Exception {
    Files.writeString(Path.of(path), new GsonBuilder().disableHtmlEscaping().create().toJson(json) + "\n");
  }

  static final LevelBasedPermissionSet[] LEVELS = {
    LevelBasedPermissionSet.ALL, LevelBasedPermissionSet.MODERATOR, LevelBasedPermissionSet.GAMEMASTER,
    LevelBasedPermissionSet.ADMIN, LevelBasedPermissionSet.OWNER};

  // ---- tree ----

  static JsonObject tree() throws Exception {
    var paths = new IdentityHashMap<CommandNode<CommandSourceStack>, List<String>>();
    collectPaths(dispatcher.getRoot(), List.of(), paths);
    var root = new JsonObject();
    var version = SharedConstants.getCurrentVersion();
    root.addProperty("version", version.name());
    root.addProperty("data_version", version.dataVersion().version());
    root.addProperty("server_sha1", VersionMetadata.serverSha1());
    root.add("children", children(dispatcher.getRoot(), paths));
    return root;
  }

  static void collectPaths(CommandNode<CommandSourceStack> node, List<String> path,
      Map<CommandNode<CommandSourceStack>, List<String>> paths) {
    paths.put(node, path);
    for (var child : node.getChildren()) {
      var next = new ArrayList<>(path);
      next.add(child.getName());
      collectPaths(child, next, paths);
    }
  }

  // Game rule literals come from an identity hash map, so vanilla's own order varies by run.
  static JsonArray children(CommandNode<CommandSourceStack> node, Map<CommandNode<CommandSourceStack>, List<String>> paths) {
    var out = new JsonArray();
    var children = new ArrayList<>(node.getChildren());
    if (paths.get(node).equals(List.of("gamerule"))) children.sort(Comparator.comparing(CommandNode::getName));
    for (var child : children) out.add(node(child, paths));
    return out;
  }

  // ---- facts: game rules, timelines and time markers ----

  static <T> String serialize(net.minecraft.world.level.gamerules.GameRule<T> rule) {
    return rule.serialize(rule.defaultValue());
  }

  static JsonObject facts() throws Exception {
    var version = SharedConstants.getCurrentVersion();
    var out = new JsonObject();
    out.addProperty("version", version.name());
    out.addProperty("data_version", version.dataVersion().version());
    out.addProperty("server_sha1", VersionMetadata.serverSha1());
    var rules = new JsonArray();
    for (var rule : BuiltInRegistries.GAME_RULE) {
      if (!rule.requiredFeatures().isSubsetOf(FeatureFlags.DEFAULT_FLAGS)) continue;
      var row = new JsonObject();
      row.addProperty("id", rule.id());
      row.addProperty("type", rule.valueClass() == Boolean.class ? "bool" : "int");
      row.addProperty("default", serialize(rule));
      rules.add(row);
    }
    out.add("game_rules", rules);
    var timelines = new JsonObject();
    var markers = new JsonObject();
    var registry = lookup.lookupOrThrow(net.minecraft.core.registries.Registries.TIMELINE);
    registry.listElements().sorted(Comparator.comparing(h -> h.key().identifier().toString())).forEach(holder -> {
      var timeline = holder.value();
      var row = new JsonObject();
      row.addProperty("clock", timeline.clock().unwrapKey().orElseThrow().identifier().toString());
      timeline.periodTicks().ifPresent(p -> row.addProperty("period", p));
      timelines.add(holder.key().identifier().toString(), row);
      timeline.registerTimeMarkers((key, marker) -> {
        var m = new JsonObject();
        m.addProperty("clock", marker.clock().unwrapKey().orElseThrow().identifier().toString());
        m.addProperty("ticks", marker.ticks());
        marker.periodTicks().ifPresent(p -> m.addProperty("period", p));
        m.addProperty("suggested", marker.showInCommands());
        markers.add(key.identifier().toString(), m);
      });
    });
    out.add("timelines", timelines);
    var info = new JsonObject();
    info.addProperty("id", version.id());
    info.addProperty("name", version.name());
    info.addProperty("data", version.dataVersion().version());
    info.addProperty("series", version.dataVersion().series());
    info.addProperty("protocol", version.protocolVersion());
    info.addProperty("build_time_ms", version.buildTime().getTime());
    info.addProperty("resource_pack", version.packVersion(net.minecraft.server.packs.PackType.CLIENT_RESOURCES).toString());
    info.addProperty("data_pack", version.packVersion(net.minecraft.server.packs.PackType.SERVER_DATA).toString());
    info.addProperty("stable", version.stable());
    out.add("server_version", info);
    out.add("time_markers", markers);
    return out;
  }

  static JsonObject node(CommandNode<CommandSourceStack> node, Map<CommandNode<CommandSourceStack>, List<String>> paths) {
    var out = new JsonObject();
    out.addProperty("name", node.getName());
    int level = -1;
    for (int i = 0; i < LEVELS.length; i++)
      if (node.canUse(Commands.createCompilationContext(LEVELS[i]))) { level = i; break; }
    if (level < 0) throw new AssertionError("Node usable at no permission level: " + paths.get(node));
    out.addProperty("level", level);
    out.addProperty("restricted", !node.canUse(Commands.createCompilationContext(PermissionSet.NO_PERMISSIONS)));
    out.addProperty("executable", node.getCommand() != null);
    if (node instanceof ArgumentCommandNode<CommandSourceStack, ?> argument) {
      out.addProperty("type", "argument");
      argument(out, argument.getType());
      var custom = argument.getCustomSuggestions();
      if (custom != null) out.addProperty("suggestions", SuggestionProviders.getName(custom).toString());
    } else {
      out.addProperty("type", "literal");
    }
    if (node.getRedirect() != null) {
      var target = new JsonArray();
      paths.get(node.getRedirect()).forEach(target::add);
      out.add("redirect", target);
      out.addProperty("fork", node.isFork());
      out.addProperty("modifier", node.getRedirectModifier() != null);
    }
    if (!node.getChildren().isEmpty()) out.add("children", children(node, paths));
    return out;
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  static void argument(JsonObject out, ArgumentType<?> type) {
    ArgumentTypeInfo.Template template = ArgumentTypeInfos.unpack((ArgumentType) type);
    ArgumentTypeInfo info = template.type();
    out.addProperty("parser", BuiltInRegistries.COMMAND_ARGUMENT_TYPE.getKey(info).toString());
    out.addProperty("parser_id", BuiltInRegistries.COMMAND_ARGUMENT_TYPE.getId(info));
    var properties = new JsonObject();
    info.serializeToJson(template, properties);
    if (!properties.isEmpty()) out.add("properties", properties);
    var buffer = new FriendlyByteBuf(Unpooled.buffer());
    info.serializeToNetwork(template, buffer);
    var bytes = new byte[buffer.readableBytes()];
    buffer.readBytes(bytes);
    out.addProperty("bytes", HexFormat.of().formatHex(bytes));
  }

  // ---- parse cases ----

  static final String[] INPUTS = {
    "", " ", "missing", "MISSING", "gamemode", "gamemode ", "gamemode  creative", "gamemode creative",
    "gamemode creative ", "gamemode Creative", "gamemode creative @s", "gamemode creative @s extra",
    "gamemode survival Alice", "gamemode survival @a[", "gamemode survival @a[gamemode=creative]",
    "gamemode spectator @e", "gamemode adventure @x", "gamemode adventure @a[limit=0]",
    "gamemode adventure @a[limit=1,sort=nearest]", "gamemode adventure @a[sort=random,limit=2]",
    "gamemode adventure @a[sort=furthest", "gamemode adventure @p[distance=..5]",
    "gamemode adventure @a[distance=-1]", "gamemode adventure @a[x=1,y=2,z=3,dx=4]",
    "gamemode adventure @a[name=Alice,name=Bob]", "gamemode adventure @a[name=!Alice,name=!Bob]",
    "gamemode adventure @a[level=3..,gamemode=!survival]", "gamemode adventure @a[unknown=1]",
    "gamemode adventure @a[tag=a,tag=!b]", "gamemode adventure @a[type=player]",
    "gamemode adventure @a[type=minecraft:pig]", "gamemode adventure @e[type=minecraft:pig]",
    "gamemode adventure @e[type=minecraft:nonsense]", "gamemode adventure @a[x_rotation=..90]",
    "gamemode adventure 0123", "gamemode adventure dd12be42-52a9-4a91-a8a1-11c01849e498",
    "gamemode adventure ThisNameIsWayTooLongForAPlayer", "gamemode adventure \"quoted\"",
    "defaultgamemode creative", "defaultgamemode hardcore",
    "tp", "tp ~ ~ ~", "tp ~1 ~-2 ~.5", "tp 1 2", "tp 1 2 3", "tp 1.5 -60 ~", "tp ^ ^ ^1", "tp ^1 ~ 2",
    "tp 1 2 3 4", "tp @s 1 2 3 90 0", "tp @s 1 2 3 ~ ~-10", "tp @s 1 2 3 facing 4 5 6",
    "tp @s 1 2 3 facing entity @p", "tp @s 1 2 3 facing entity @p eyes", "tp @s 1 2 3 facing entity @p chest",
    "tp @s @p", "tp @a @p", "tp @p @a", "tp Alice Bob", "teleport @s ~ ~10 ~", "tp ~ ~ ~ ~ ~",
    "tp 30000000 0 0", "tp 1e5 0 0", "tp - 0 0", "tp 1 .5 -.5", "tp 1..2 0 0", "tp ~~ ~ ~",
    "give", "give @s", "give @s stone", "give @s minecraft:stone 64", "give @s stone 0", "give @s stone -1",
    "give @s stone 2147483648", "give @s stone 1.5", "give @s nonsense_item", "give @s stone[", "give @s stone{}",
    "give @s diamond_sword[damage=5]", "give @s diamond_sword[minecraft:damage=5] 2", "give @s stone[nonsense=1]",
    "give @s #minecraft:logs", "give @e stone", "give @a STONE",
    "clear", "clear @s", "clear @s stone", "clear @s stone 0", "clear @s #minecraft:logs 3", "clear @s *",
    "clear @s stone[damage=1]", "clear @s #minecraft:nonsense", "clear @e",
    "time", "time set day", "time set 1000", "time set 1d", "time set 20s", "time set 3t", "time set 1x",
    "time set -1", "time add -5", "time query gametime", "time query daytime", "time query day",
    "time set noon", "time set minecraft:noon", "time rate 2", "time pause",
    "weather clear", "weather rain 100", "weather thunder 0", "weather thunder 1d", "weather snow",
    "difficulty", "difficulty peaceful", "difficulty hard", "difficulty 2", "difficulty extreme",
    "gamerule", "gamerule keep_inventory", "gamerule keep_inventory true", "gamerule keep_inventory yes",
    "gamerule random_tick_speed 5", "gamerule random_tick_speed -1", "gamerule keepInventory true",
    "setblock 1 2 3 stone", "setblock 1 2 3 minecraft:oak_stairs[facing=east]", "setblock 1 2 3 oak_stairs[facing=up]",
    "setblock 1 2 3 oak_stairs[nonsense=1]", "setblock 1 2 3 oak_stairs[facing=east,facing=west]",
    "setblock 1 2 3 stone keep", "setblock 1 2 3 stone destroy", "setblock 1 2 3 stone nope",
    "setblock ~ ~-1 ~ chest{}", "setblock 1 2 stone", "setblock 1.5 2 3 stone", "setblock ^ ^ ^ stone",
    "setblock 1 2 3 #minecraft:logs", "setblock 1 2 3 oak_stairs[facing=east", "setblock 1 2 3 nonsense",
    "fill 0 0 0 1 1 1 stone", "fill 0 0 0 1 1 1 stone hollow", "fill 0 0 0 1 1 1 stone replace",
    "fill 0 0 0 1 1 1 stone replace dirt", "fill 0 0 0 1 1 1 stone replace #minecraft:logs keep",
    "fill 0 0 0 1 1 1 air replace oak_stairs[facing=east]",
    "summon", "summon pig", "summon minecraft:item ~ ~ ~", "summon experience_orb 1 2 3 {Value:5}",
    "summon nonsense", "summon item ~ ~ ~ {", "summon player",
    "kill", "kill @s", "kill @e[type=item]", "kill @e[type=!player,distance=..10]",
    "effect give @s speed", "effect give @s minecraft:speed 30 1 true", "effect give @s speed infinite 2",
    "effect give @s speed 0", "effect give @s speed 30 256", "effect give @s nonsense",
    "effect clear @s", "effect clear @s speed", "effect clear",
    "xp add @s 5", "xp add @s 5 levels", "xp add @s -5 points", "xp set @s -1", "xp query @s",
    "xp query @a points", "experience query @s levels", "xp add @s 5 nope",
    "spawnpoint", "spawnpoint @s ~ ~ ~", "spawnpoint @s 1 2 3 90", "spawnpoint @s 1 2 3 90 0",
    "setworldspawn", "setworldspawn 1 2 3", "setworldspawn 1 2 3 45", "setworldspawn 1 2 3 45 10",
    "say", "say hello", "say  spaced  out ", "say hi @a", "say @s", "me waves", "me",
    "msg", "msg Alice", "msg Alice hi there", "tell @a hello", "w @p psst", "msg @e hi",
    "list", "list uuids", "list nope", "seed",
    "locate biome minecraft:plains", "locate biome #minecraft:is_forest", "locate biome nonsense",
    "locate structure village_plains", "locate structure #minecraft:village", "locate poi",
    "help", "help gamemode", "help nonsense", "help gamemode creative",
    "stats", "spawn", "stats extra", "/gamemode creative",
    "time of minecraft:overworld query time", "time of minecraft:nonsense set 5", "time of the_end pause",
    "time query minecraft:day repetition", "time query minecraft:nonsense", "time rate 0", "time rate 1001",
    "time set minecraft:wake_up_from_sleep", "time set Noon", "time add 1.5d", "weather rain 0.5",
    "gamerule minecraft:advance_time false", "gamerule advance_time maybe", "gamerule natural_health_regeneration",
    "fill 0 0 0 1 1 1 stone destroy", "setblock 1 2 3 stone destroy", "fill 0 0 0 1 1 stone", "fill ~ ~ ~ ~1 ~1 ~1 glass outline",
    "list uuids", "msg @a hi", "me waves at @p", "say hi @e[", "say hi @", "say hi @z there", "msg Alice @a[limit=",
    "locate biome minecraft:plains extra", "setworldspawn ~ ~ ~ ~ ~",
    "xp add Alice 10 points", "xp set @a 0 levels", "xp query @a points", "effect give @a speed infinite",
    "give @a minecraft:stone 6400", "clear @a minecraft:stone 2147483648", "kill @a[limit=1]", "tp @e[type=item] ~ ~ ~",
  };

  static JsonArray cases() {
    var out = new JsonArray();
    for (int level : new int[]{4, 0})
      for (var input : INPUTS) {
        var c = new JsonObject();
        c.addProperty("level", level);
        c.addProperty("input", input);
        out.add(c);
      }
    return out;
  }

  // ---- verify ----

  static void verify(Path graphs, Path resultsPath) throws Exception {
    var results = JsonParser.parseString(Files.readString(resultsPath)).getAsJsonArray();
    var expectedTree = tree().getAsJsonArray("children");
    int nodes = 0;
    var covered = new HashMap<Integer, Set<String>>();
    for (int level : new int[]{0, 4}) {
      var payload = HexFormat.of().parseHex(Files.readString(graphs.resolve("graph-" + level + ".hex")).strip());
      var buffer = new FriendlyByteBuf(Unpooled.wrappedBuffer(payload));
      var packet = ClientboundCommandsPacket.STREAM_CODEC.decode(buffer);
      if (buffer.isReadable()) throw new AssertionError("Trailing graph bytes at level " + level);
      var root = packet.getRoot(CommandBuildContext.simple(lookup, FeatureFlags.DEFAULT_FLAGS), new Builder());
      nodes += compareChildren(root, expectedTree, level, "");
      var paths = new HashSet<String>();
      collect(root, "", paths);
      covered.put(level, paths);
    }
    var vanillaPaths = new IdentityHashMap<CommandNode<CommandSourceStack>, List<String>>();
    collectPaths(dispatcher.getRoot(), List.of(), vanillaPaths);
    int outside = 0, unsupported = 0;
    int compared = 0;
    for (var element : results) {
      var result = element.getAsJsonObject();
      var input = result.get("input").getAsString();
      int level = result.get("level").getAsInt();
      var word = Commands.trimOptionalPrefix(input).split(" ", -1)[0];
      if (word.equals("stats") || word.equals("spawn")) {
        outside++;
        continue;
      }
      var expected = vanillaOutcome(input, level);
      boolean inside = true;
      for (var context = dispatcher.parse(Commands.trimOptionalPrefix(input), Commands.createCompilationContext(LEVELS[level])).getContext();
           context != null; context = context.getChild())
        for (var parsed : context.getNodes())
          if (!covered.get(level).contains("/" + String.join("/", vanillaPaths.get(parsed.getNode())))) inside = false;
      if (!inside) {
        if (!result.has("messages")) throw new AssertionError("ValiMC executes /" + input + " outside its graph");
        outside++;
        continue;
      }
      if (result.has("messages") && unsupported(decode(result.getAsJsonArray("messages").get(0).getAsString()))) {
        unsupported++;
        continue;
      }
      var actual = new JsonObject();
      if (result.has("path")) actual.add("path", result.get("path"));
      if (result.has("arguments")) actual.add("arguments", result.get("arguments"));
      if (result.has("messages")) {
        var messages = new JsonArray();
        for (var hex : result.getAsJsonArray("messages")) messages.add(componentJson(decode(hex.getAsString())));
        actual.add("messages", messages);
      }
      if (!expected.equals(actual))
        throw new AssertionError("Parse differs at level " + level + " for /" + input + "\n vanilla " + expected + "\n valimc  " + actual);
      compared++;
    }
    if (compared + outside + unsupported != INPUTS.length * 2) throw new AssertionError("Missing parse results: " + compared);
    System.out.println("PASS: Mojang decoded ValiMC's graphs (" + nodes + " nodes at levels 0 and 4) as vanilla's "
      + "usable tree pruned to implemented commands; " + compared + " parse outcomes equal vanilla's; " + outside
      + " inputs reach commands ValiMC does not implement yet and fail; " + unsupported
      + " need SNBT (VMC-053g) and are refused.");
  }

  /** ValiMC's explicit refusal of syntax it does not implement yet: red literal "... not supported yet". */
  static boolean unsupported(Component message) {
    return message.getSiblings().size() == 1 && message.getSiblings().get(0).getString().endsWith("not supported yet");
  }

  static void collect(CommandNode<Object> node, String path, Set<String> out) {
    for (var child : node.getChildren()) {
      String here = path + "/" + child.getName();
      out.add(here);
      collect(child, here, out);
    }
  }

  /** Vanilla's usable children of `actual` in order, keeping only those ValiMC sends. */
  static int compareChildren(CommandNode<Object> actual, JsonArray expected, int level, String path) {
    int count = 0;
    var usable = new ArrayList<JsonObject>();
    for (var e : expected) if (e.getAsJsonObject().get("level").getAsInt() <= level) usable.add(e.getAsJsonObject());
    int cursor = 0;
    for (var child : actual.getChildren()) {
      String here = path + "/" + child.getName();
      if (child.getName().equals("stats") || child.getName().equals("spawn")) {
        if (!path.isEmpty() || child.getCommand() == null || !child.getChildren().isEmpty()) throw new AssertionError("ValiMC literal " + here);
        count++;
        continue;
      }
      while (cursor < usable.size() && !usable.get(cursor).get("name").getAsString().equals(child.getName())) cursor++;
      if (cursor == usable.size()) throw new AssertionError("Node absent, unusable or out of order in vanilla: " + here);
      var vanilla = usable.get(cursor++);
      var shape = new JsonObject();
      shape.addProperty("type", child instanceof ArgumentCommandNode ? "argument" : "literal");
      if (child instanceof ArgumentCommandNode<Object, ?> argument) {
        argument(shape, argument.getType());
        if (argument.getCustomSuggestions() != null)
          shape.addProperty("suggestions", ((Suggesting) argument.getCustomSuggestions()).id.toString());
      }
      shape.addProperty("restricted", Builder.restricted.contains(child));
      for (var key : List.of("type", "parser", "parser_id", "properties", "bytes", "suggestions", "restricted"))
        if (!Objects.equals(shape.get(key), vanilla.get(key)))
          throw new AssertionError("Node " + here + " differs in " + key + ": vanilla " + vanilla.get(key) + ", valimc " + shape.get(key));
      if (child.getCommand() != null && !vanilla.get("executable").getAsBoolean())
        throw new AssertionError("Node executable only in ValiMC: " + here);
      if (vanilla.has("redirect")) {
        if (child.getRedirect() == null) throw new AssertionError("Missing redirect at " + here);
        var target = new ArrayList<String>();
        for (var node = child.getRedirect(); node != null && !(node instanceof RootCommandNode); node = Builder.parents.get(node))
          target.addFirst(node.getName());
        var expectedTarget = new ArrayList<String>();
        vanilla.getAsJsonArray("redirect").forEach(s -> expectedTarget.add(s.getAsString()));
        if (!target.equals(expectedTarget)) throw new AssertionError("Redirect differs at " + here + ": " + target);
      } else if (child.getRedirect() != null) throw new AssertionError("Unexpected redirect at " + here);
      count += 1 + compareChildren(child, vanilla.has("children") ? vanilla.getAsJsonArray("children") : new JsonArray(), level,
        here);
    }
    if (path.isEmpty() && count == 0) throw new AssertionError("Empty graph");
    return count;
  }

  record Suggesting(Identifier id) implements com.mojang.brigadier.suggestion.SuggestionProvider<Object> {
    public java.util.concurrent.CompletableFuture<com.mojang.brigadier.suggestion.Suggestions> getSuggestions(
        CommandContext<Object> c, com.mojang.brigadier.suggestion.SuggestionsBuilder b) {
      return b.buildFuture();
    }
  }

  static class Builder implements ClientboundCommandsPacket.NodeBuilder<Object> {
    static final Set<Object> restricted = Collections.newSetFromMap(new IdentityHashMap<>());
    static final Map<CommandNode<Object>, CommandNode<Object>> parents = new IdentityHashMap<>();

    public ArgumentBuilder<Object, ?> createLiteral(String name) { return new Tracked<>(LiteralArgumentBuilder.literal(name)); }

    public ArgumentBuilder<Object, ?> createArgument(String name, ArgumentType<?> type, Identifier suggestion) {
      var builder = RequiredArgumentBuilder.<Object, Object>argument(name, (ArgumentType<Object>) type);
      if (suggestion != null) builder.suggests(new Suggesting(suggestion));
      return new Tracked<>(builder);
    }

    public ArgumentBuilder<Object, ?> configure(ArgumentBuilder<Object, ?> builder, boolean executable, boolean isRestricted) {
      if (executable) builder.executes(c -> 1);
      ((Tracked<?>) builder).restricted = isRestricted;
      return builder;
    }
  }

  /** Wraps a builder to remember the restricted flag and parents of the nodes it builds. */
  static class Tracked<T extends ArgumentBuilder<Object, T>> extends ArgumentBuilder<Object, Tracked<T>> {
    final ArgumentBuilder<Object, ?> inner;
    boolean restricted;

    Tracked(ArgumentBuilder<Object, ?> inner) { this.inner = inner; }

    protected Tracked<T> getThis() { return this; }

    public Tracked<T> then(CommandNode<Object> argument) { inner.then(argument); return this; }

    public Tracked<T> executes(com.mojang.brigadier.Command<Object> command) { inner.executes(command); return this; }

    public Tracked<T> forward(CommandNode<Object> target, com.mojang.brigadier.RedirectModifier<Object> modifier, boolean fork) {
      inner.forward(target, modifier, fork);
      return this;
    }

    public CommandNode<Object> build() {
      var node = inner.build();
      for (var child : node.getChildren()) Builder.parents.put(child, node);
      if (restricted) Builder.restricted.add(node);
      return node;
    }
  }

  // ---- vanilla parse outcome ----

  static JsonObject vanillaOutcome(String input, int level) throws Exception {
    var messages = new ArrayList<Component>();
    CommandSource capture = new CommandSource() {
      public void sendSystemMessage(Component message) { messages.add(message); }
      public boolean acceptsSuccess() { return true; }
      public boolean acceptsFailure() { return true; }
      public boolean shouldInformAdmins() { return false; }
    };
    var source = Commands.createCompilationContext(LEVELS[level]).withSource(capture);
    String command = Commands.trimOptionalPrefix(input);
    ParseResults<CommandSourceStack> parse = dispatcher.parse(command, source);
    Method finish = Commands.class.getDeclaredMethod("finishParsing", ParseResults.class, String.class, CommandSourceStack.class);
    finish.setAccessible(true);
    var chain = finish.invoke(null, parse, command, source);
    var out = new JsonObject();
    if (chain != null) {
      var path = new JsonArray();
      CommandContext<CommandSourceStack> last = null;
      for (var context = parse.getContext().build(command); context != null; context = context.getChild()) {
        var names = context.getNodes().stream().map(n -> n.getNode().getName()).collect(Collectors.joining(" "));
        path.add(names);
        last = context;
      }
      out.add("path", path);
      var arguments = new JsonObject();
      for (var name : argumentNames(parse.getContext()))
        arguments.addProperty(name, argumentText(parse.getContext(), name, command));
      out.add("arguments", arguments);
    } else {
      var array = new JsonArray();
      for (var message : messages) array.add(componentJson(message));
      out.add("messages", array);
    }
    return out;
  }

  static List<String> argumentNames(CommandContextBuilder<CommandSourceStack> context) {
    while (context.getChild() != null) context = context.getChild();
    return context.getArguments().keySet().stream().sorted().toList();
  }

  static String argumentText(CommandContextBuilder<CommandSourceStack> context, String name, String input) {
    while (context.getChild() != null) context = context.getChild();
    return context.getArguments().get(name).getRange().get(input);
  }

  static Component decode(String hex) {
    var buffer = Unpooled.wrappedBuffer(HexFormat.of().parseHex(hex));
    var component = ComponentSerialization.TRUSTED_CONTEXT_FREE_STREAM_CODEC.decode(buffer);
    if (buffer.isReadable()) throw new AssertionError("Trailing component bytes");
    return component;
  }

  static JsonElement componentJson(Component component) {
    return ComponentSerialization.CODEC.encodeStart(com.mojang.serialization.JsonOps.INSTANCE, component).getOrThrow();
  }
}
