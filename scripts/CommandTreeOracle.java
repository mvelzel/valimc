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
    // Item component types a command may name (`ItemParser.readComponentType`).
    var components = new JsonArray();
    BuiltInRegistries.DATA_COMPONENT_TYPE.keySet().stream().map(Object::toString).sorted().forEach(id -> {
      var type = BuiltInRegistries.DATA_COMPONENT_TYPE.getValue(Identifier.parse(id));
      if (!type.isTransient()) components.add(id);
    });
    out.add("item_components", components);
    var predicates = new JsonArray();
    BuiltInRegistries.DATA_COMPONENT_PREDICATE_TYPE.keySet().stream().map(Object::toString).sorted().forEach(predicates::add);
    out.add("item_predicates", predicates);
    // Particle types: network id and, for types that need options, vanilla's message for `{}`.
    var particles = new JsonArray();
    for (var type : BuiltInRegistries.PARTICLE_TYPE) {
      var row = new JsonObject();
      row.addProperty("id", BuiltInRegistries.PARTICLE_TYPE.getKey(type).toString());
      row.addProperty("network_id", BuiltInRegistries.PARTICLE_TYPE.getId(type));
      var ops = lookup.createSerializationContext(net.minecraft.nbt.NbtOps.INSTANCE);
      type.codec().codec().parse(ops, new net.minecraft.nbt.CompoundTag()).error()
        .ifPresent(e -> row.addProperty("missing_options", e.message()));
      particles.add(row);
    }
    out.add("particles", particles);
    var dialogs = new JsonArray();
    lookup.lookupOrThrow(net.minecraft.core.registries.Registries.DIALOG).listElementIds()
      .map(k -> k.identifier().toString()).sorted().forEach(dialogs::add);
    out.add("dialogs", dialogs);
    LocateOracle.facts(StructureOracle.serverRegistries()).entrySet().forEach(e -> out.add(e.getKey(), e.getValue()));
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
    "give @a minecraft:stone 6400",
    "give @s diamond_sword[damage=5]", "give @s diamond_sword[damage=-1]", "give @s diamond_sword[damage=\"x\"]",
    "give @s diamond_sword[damage=5b]", "give @s stone[max_stack_size=100]", "give @s stone[max_stack_size=64]",
    "give @s stone[unbreakable={}]", "give @s stone[enchantment_glint_override=true]", "give @s stone[custom_data={a:1,b:[1,2]}]",
    "give @s stone[!max_stack_size]", "give @s stone[damage=1,damage=2]", "give @s stone[damage=1,]", "give @s stone[ minecraft:damage = 3 ]",
    "give @s stone[damage=1", "give @s stone[damage=]", "give @s stone[damage=1 2]", "give @s stone[max_damage=0]", "give @s stone[damage=3.7]",
    "give @s stone[damage=1]]", "give @s stone[]", "give @s stone[,]", "give @s stone[!]", "give @s stone[damage=01]",
    "setblock 1 2 3 chest{}", "setblock 1 2 3 chest{Items:[]}", "setblock 1 2 3 chest{", "setblock 1 2 3 chest{a:1}x",
    "setblock 1 2 3 stone[]{}", "fill 0 0 0 1 1 1 chest{a:\"b\"} replace",
    "gamemode creative @a[nbt={}]", "gamemode creative @a[nbt=!{a:1b}]", "gamemode creative @a[nbt=5]", "gamemode creative @a[nbt={a:]",
    "kill @e[nbt={Tags:[\"x\"]},type=item]",
    "setblock 1 2 3 chest{v:1}", "setblock 1 2 3 chest{v:-1}", "setblock 1 2 3 chest{v:+5}", "setblock 1 2 3 chest{v:1b}", "setblock 1 2 3 chest{v:1B}", "setblock 1 2 3 chest{v:1s}", "setblock 1 2 3 chest{v:1L}", "setblock 1 2 3 chest{v:1ub}", "setblock 1 2 3 chest{v:1sb}", "setblock 1 2 3 chest{v:1us}", "setblock 1 2 3 chest{v:1ui}", "setblock 1 2 3 chest{v:1ul}", "setblock 1 2 3 chest{v:255ub}", "setblock 1 2 3 chest{v:256ub}", "setblock 1 2 3 chest{v:-1ub}", "setblock 1 2 3 chest{v:128b}", "setblock 1 2 3 chest{v:127b}", "setblock 1 2 3 chest{v:32768s}", "setblock 1 2 3 chest{v:2147483648}", "setblock 1 2 3 chest{v:2147483648L}", "setblock 1 2 3 chest{v:9223372036854775808L}", "setblock 1 2 3 chest{v:18446744073709551615ul}", "setblock 1 2 3 chest{v:18446744073709551616ul}", "setblock 1 2 3 chest{v:0x}", "setblock 1 2 3 chest{v:0xFF}", "setblock 1 2 3 chest{v:0xffb}", "setblock 1 2 3 chest{v:0xFFFFFFFF}", "setblock 1 2 3 chest{v:0x1_00}", "setblock 1 2 3 chest{v:0x_1}", "setblock 1 2 3 chest{v:0b101}", "setblock 1 2 3 chest{v:0b2}", "setblock 1 2 3 chest{v:0b}", "setblock 1 2 3 chest{v:01}", "setblock 1 2 3 chest{v:00}", "setblock 1 2 3 chest{v:0_1}", "setblock 1 2 3 chest{v:1_000}", "setblock 1 2 3 chest{v:1__0}", "setblock 1 2 3 chest{v:1_}", "setblock 1 2 3 chest{v:_1}", "setblock 1 2 3 chest{v:1.5}", "setblock 1 2 3 chest{v:1.}", "setblock 1 2 3 chest{v:.5}", "setblock 1 2 3 chest{v:.}", "setblock 1 2 3 chest{v:1e3}", "setblock 1 2 3 chest{v:1E-3}", "setblock 1 2 3 chest{v:1e}", "setblock 1 2 3 chest{v:1.5f}", "setblock 1 2 3 chest{v:1.5F}", "setblock 1 2 3 chest{v:1.5d}", "setblock 1 2 3 chest{v:1e3f}", "setblock 1 2 3 chest{v:3.4e39f}", "setblock 1 2 3 chest{v:1e309}", "setblock 1 2 3 chest{v:1.5b}", "setblock 1 2 3 chest{v:1fb}", "setblock 1 2 3 chest{v:-.5}", "setblock 1 2 3 chest{v:+.5e+2}", "setblock 1 2 3 chest{v:1.5e1_0}", "setblock 1 2 3 chest{v:1i}", "setblock 1 2 3 chest{v:1.0i}", "setblock 1 2 3 chest{v:\"a\"}", "setblock 1 2 3 chest{v:'a'}", "setblock 1 2 3 chest{v:\"a'b\"}", "setblock 1 2 3 chest{v:'a\"b'}", "setblock 1 2 3 chest{v:\"a\\\"b\"}", "setblock 1 2 3 chest{v:'a\\'b'}", "setblock 1 2 3 chest{v:\"\\n\\t\\s\\b\"}", "setblock 1 2 3 chest{v:\"\\x41\"}", "setblock 1 2 3 chest{v:\"\\x4\"}", "setblock 1 2 3 chest{v:\"é\"}", "setblock 1 2 3 chest{v:\"\\U0001F600\"}", "setblock 1 2 3 chest{v:\"\\U00110000\"}", "setblock 1 2 3 chest{v:\"\\q\"}", "setblock 1 2 3 chest{v:\"\\N{SPACE}\"}", "setblock 1 2 3 chest{v:\"unterminated}", "setblock 1 2 3 chest{v:''}", "setblock 1 2 3 chest{v:abc}", "setblock 1 2 3 chest{v:true}", "setblock 1 2 3 chest{v:FALSE}", "setblock 1 2 3 chest{v:True}", "setblock 1 2 3 chest{v:bool(1)}", "setblock 1 2 3 chest{v:bool(0)}", "setblock 1 2 3 chest{v:bool(\"x\")}", "setblock 1 2 3 chest{v:bool(1.5)}", "setblock 1 2 3 chest{v:bool(256)}", "setblock 1 2 3 chest{v:bool()}", "setblock 1 2 3 chest{v:bool(1,2)}", "setblock 1 2 3 chest{v:uuid(\"dd12be42-52a9-4a91-a8a1-11c01849e498\")}", "setblock 1 2 3 chest{v:uuid(\"x\")}", "setblock 1 2 3 chest{v:uuid(1)}", "setblock 1 2 3 chest{v:foo(1)}", "setblock 1 2 3 chest{v:foo(}", "setblock 1 2 3 chest{v:1abc}", "setblock 1 2 3 chest{v:[]}", "setblock 1 2 3 chest{v:[1,2,3]}", "setblock 1 2 3 chest{v:[1,\"a\"]}", "setblock 1 2 3 chest{v:[1,]}", "setblock 1 2 3 chest{v:[,]}", "setblock 1 2 3 chest{v:[1 2]}", "setblock 1 2 3 chest{v:[B;1b,2b]}", "setblock 1 2 3 chest{v:[B;1,2]}", "setblock 1 2 3 chest{v:[B;1s]}", "setblock 1 2 3 chest{v:[I;1,2b,3s]}", "setblock 1 2 3 chest{v:[I;1L]}", "setblock 1 2 3 chest{v:[L;1,2L]}", "setblock 1 2 3 chest{v:[B;]}", "setblock 1 2 3 chest{v:[X;1]}", "setblock 1 2 3 chest{v:[B;1}", "setblock 1 2 3 chest{v:[I;1b,]}", "setblock 1 2 3 chest{v:{}}", "setblock 1 2 3 chest{v:{a:1}}", "setblock 1 2 3 chest{v:{a:1,}}", "setblock 1 2 3 chest{v:{\"a b\":1}}", "setblock 1 2 3 chest{v:{'':1}}", "setblock 1 2 3 chest{v:{:1}}", "setblock 1 2 3 chest{v:{a:1,a:2}}", "setblock 1 2 3 chest{v:{a b:1}}", "setblock 1 2 3 chest{v:{a:{b:{c:[1]}}}}", "setblock 1 2 3 chest{v:{ a : 1 }}", "setblock 1 2 3 chest{v:{a:1 b:2}}", "setblock 1 2 3 chest{v:{a}", "setblock 1 2 3 chest{v:{1:2}}", "setblock 1 2 3 chest{v:{+:1}}", "setblock 1 2 3 chest{v:1}", "setblock 1 2 3 chest[facing=east]{v:1}", "setblock 1 2 3 chest{}{}", "setblock 1 2 3 chest[]{", "setblock 1 2 3 chest 1", "setblock 1 2 3 chest{  }",
    "tellraw @s \"hello\"", "tellraw @s 'hi'", "tellraw @s \"\"", "tellraw @s [\"a\",\"b\"]", "tellraw @s {text:\"a\",color:\"#FF0000\"}", "tellraw @s {translate:\"k\",with:[\"a\",1,{text:\"b\"}]}", "tellraw @s {text:\"a\",shadow_color:[1f,0f,0f,1f]}", "tellraw @s {selector:\"@p\"}", "tellraw @s {score:{name:\"*\",objective:\"o\"}}", "tellraw @s {keybind:\"key.jump\"}", "tellraw @s 123", "tellraw @s true", "tellraw @s []", "tellraw @s {}", "tellraw @s {foo:1}", "tellraw @s {text:1}", "tellraw @s {translate:1}", "tellraw @s {selector:\"@q\"}", "tellraw @s {type:\"bogus\",text:\"x\"}", "tellraw @s {type:\"text\"}", "tellraw @s {text:\"a\",color:\"blurple\"}", "tellraw @s {text:\"a\",color:1}", "tellraw @s {text:\"a\",bold:\"yes\"}", "tellraw @s {text:\"a\",extra:[]}", "tellraw @s {text:\"a\",extra:\"b\"}", "tellraw @s {text:\"a\",click_event:{action:\"bogus\"}}", "tellraw @s {text:\"a\",hover_event:{action:\"show_text\",value:1}}", "tellraw @s [1,2]", "tellraw @s hello world", "tellraw @s {text:\"a\"", "tellraw @s {text:a b}", "tellraw @s \"unterminated", "tellraw @s ", "tellraw @s {text:\"a\",bold:2}", "tellraw @s {text:\"a\",foo:1}", "tellraw @s {text:\"a\",click_event:{action:\"open_url\"}}", "tellraw @s {text:\"a\",click_event:{action:\"change_page\",page:0}}", "tellraw @s {text:\"a\",click_event:{action:\"run_command\",command:\"/say hi\"}}", "tellraw @s {text:\"a\",hover_event:{action:\"show_text\",value:\"tip\"}}", "tellraw @s {text:\"a\",color:\"#12345\"}", "tellraw @s [\"a\",1]", "tellraw @s {text:\"a\",extra:[\"b\",{text:\"c\",bold:1b}]}", "tellraw @s {type:\"translatable\",translate:\"x\"}", "tellraw @s {type:\"keybind\"}", "tellraw @s {type:1}", "tellraw @s {text:\"a\",insertion:1}", "tellraw @s {text:\"a\",color:\"red\",italic:true}", "title @s title {text:\"T\"}", "title @s subtitle \"S\"", "title @s actionbar 1", "title @s times 10 70 20", "title @s times 1s 2s 3x", "title @s clear", "title @s reset", "title @a title", "tellraw @a",
    "particle flame", "particle minecraft:flame ~ ~1 ~", "particle flame ~ ~ ~ 1 1 1 0.1 10", "particle flame ~ ~ ~ 1 1 1 0.1 10 force", "particle flame ~ ~ ~ 1 1 1 0.1 10 normal @a", "particle Flame", "particle nonsense", "particle dust", "particle dust{color:[1f,0f,0f],scale:1f}", "particle dust{color:[1f,0f,0f]}", "particle dust{scale:1f}", "particle dust{color:16711680,scale:5f}", "particle block", "particle block{block_state:\"minecraft:stone\"}", "particle block{block_state:{Name:\"minecraft:oak_log\",Properties:{axis:\"x\"}}}", "particle entity_effect{color:-1}", "particle item", "particle flame{foo:1}", "particle flame {x:1}", "particle dust{", "particle flame ~ ~ ~ 1 1 1 -1 10", "particle flame ~ ~ ~ 1 1 1 0 -1", "particle flame ~ ~ ~ 1 1", "particle dragon_breath{power:2f}", "particle effect{color:[1f,1f,1f],power:2f}", "particle trail", "particle vibration", "playsound minecraft:entity.pig.ambient", "playsound entity.pig.ambient master", "playsound entity.pig.ambient master @s ~ ~ ~ 2 1.5 0.5", "playsound entity.pig.ambient bogus", "playsound entity.pig.ambient player @a ~ ~ ~ -1", "playsound entity.pig.ambient player @a ~ ~ ~ 1 3", "playsound entity.pig.ambient player @a ~ ~ ~ 1 1 2", "playsound Bad", "stopsound @s", "stopsound @s * minecraft:entity.pig.ambient", "stopsound @s music", "stopsound @s music entity.pig.ambient", "stopsound @s bogus", "stopsound @s *", "dialog show @s minecraft:server_links", "dialog show @s nonsense", "dialog show @s {type:\"minecraft:notice\"}", "dialog show @s 123", "dialog clear @s", "dialog clear", "dialog show @s",
    "posteffect add @s minecraft:invert", "posteffect add @s invert", "posteffect add @s Bad", "posteffect remove @s spider", "posteffect clear @s", "posteffect list @s", "posteffect list @a", "posteffect add", "stopwatch create minecraft:race", "stopwatch create Race", "stopwatch query race", "stopwatch query race 20", "stopwatch query race x", "stopwatch restart race", "stopwatch remove race", "stopwatch create", "tick query", "tick rate 20", "tick rate 0.5", "tick rate 10001", "tick rate x", "tick freeze", "tick unfreeze", "tick step", "tick step 20", "tick step 1s", "tick step 0", "tick step -1", "tick step stop", "tick sprint 100", "tick sprint 1d", "tick sprint stop", "tick sprint", "tick bogus", "forceload add 0 0", "forceload add ~ ~", "forceload add 0", "forceload add 0.5 0", "forceload add 0 0 100 100", "forceload add 0 0 1000 1000", "forceload add ^ ^", "forceload add 0 0 1", "forceload remove 0 0", "forceload remove 0 0 16 16", "forceload remove all", "forceload query", "forceload query 5 5", "forceload query 5", "forceload add 30000000 0", "forceload add x 0", "clone 0 0 0 1 1 1 5 5 5", "clone ~ ~ ~ ~1 ~1 ~1 ~5 ~ ~", "clone 0 0 0 1 1 1 5 5 5 replace", "clone 0 0 0 1 1 1 5 5 5 masked move", "clone 0 0 0 1 1 1 5 5 5 replace force", "clone 0 0 0 1 1 1 5 5 5 filtered stone", "clone 0 0 0 1 1 1 5 5 5 filtered #logs normal", "clone 0 0 0 1 1 1 5 5 5 filtered", "clone 0 0 0 1 1 1 5 5 5 strict", "clone 0 0 0 1 1 1 5 5 5 strict masked", "clone from overworld 0 0 0 1 1 1 5 5 5", "clone from minecraft:the_nether 0 0 0 1 1 1 to overworld 5 5 5", "clone from Bad 0 0 0 1 1 1 5 5 5", "clone from overworld 0 0 0 1 1 1 to nowhere 5 5 5", "clone 0 0 0 1 1 1", "clone 0 0 0 1 1 1 5 5 5 bogus", "clone 0 0 0 1 1 1 5 5 5 replace bogus", "clone 0 0", "clone 0 0 0 1 1 1 5 5 5 masked",
    "fillbiome 0 0 0 4 4 4 minecraft:desert", "fillbiome ~ ~ ~ ~4 ~4 ~4 desert replace minecraft:plains", "fillbiome 0 0 0 4 4 4 desert replace #minecraft:is_forest", "fillbiome 0 0 0 4 4 4 nonsense", "fillbiome 0 0 0 4 4 4", "fillbiome 0 0 0 4 4 4 desert replace", "fillbiome 0 0 0 4 4 4 desert bogus",
    "place feature minecraft:oak", "place feature oak 1 2 3", "place feature minecraft:nonsense", "place feature {type:\"minecraft:tree\"}", "place feature", "place feature Oak", "place jigsaw minecraft:village/plains/town_centers minecraft:bottom 2", "place jigsaw nonsense minecraft:bottom 2", "place jigsaw minecraft:village/plains/town_centers minecraft:bottom 0", "place jigsaw minecraft:village/plains/town_centers minecraft:bottom 21", "place jigsaw minecraft:village/plains/town_centers minecraft:bottom 3 ~ ~ ~", "place structure minecraft:igloo", "place structure igloo 1 2 3", "place structure nonsense", "place structure Bad", "place template minecraft:igloo/top", "place template igloo/top ~ ~ ~ clockwise_90 left_right 0.5 7 strict", "place template igloo/top ~ ~ ~ clockwise_45", "place template igloo/top ~ ~ ~ 180 sideways", "place template igloo/top ~ ~ ~ none none 1.5", "place template igloo/top ~ ~ ~ none none 0.5 x", "place template igloo/top ~ ~ ~ none none 0.5 1 lenient", "place template nonsense", "place bogus",
    "tp 0 120 0 0 30", "teleport 0 120 0 0 30", "tp 0 120 0 0", "tp @s 0 120 0 0 30", "tp ValiMCTest 0 120 0 0 30", "tp 0 120 0 facing 1 2 3", "effect give @s minecraft:night_vision", "effect give @s night_vision 30 0 true", "effect give @s minecraft:glowing infinite", "effect give @s minecraft:blindness 10",
    "save-all", "save-all flush", "save-all bogus", "save-on", "save-off", "save-on now", "setidletimeout 5", "setidletimeout 0", "setidletimeout -1", "setidletimeout x", "setidletimeout",
    "locate structure village_plains", "locate structure minecraft:mansion", "locate structure #minecraft:village", "locate structure #village", "locate structure #minecraft:nonsense", "locate structure nonsense", "locate structure Bad", "locate structure", "locate structure #", "locate structure village_plains extra", "locate structure minecraft:",
    "op Steve", "op @s", "op @e", "op @e[type=player]", "op @a", "op", "op Steve extra", "op @x", "op @p[", "op ünïcode", "deop Steve", "deop @a", "ban Steve", "ban Steve griefing a lot", "ban @a bye", "ban @e", "ban-ip 1.2.3.4", "ban-ip 1.2.3.4 spam", "ban-ip a:b", "ban-ip", "ban-ip \"1.2.3.4\"", "banlist", "banlist ips", "banlist players", "banlist bogus", "pardon Steve", "pardon @s", "pardon-ip 1.2.3.4", "pardon-ip", "whitelist on", "whitelist off", "whitelist list", "whitelist add Steve", "whitelist remove @s", "whitelist reload", "whitelist bogus", "whitelist add", "transfer example.com", "transfer \"example.com\" 25566", "transfer example.com 0", "transfer example.com 65536", "transfer example.com 25565 @a", "transfer example.com 25565 @e", "transfer example.com x",
    "clear @s nonsense", "clear @s *[damage=1]", "clear @s stone[count=5]", "clear @s stone[count={min:2,max:5}]",
    "clear @s stone[count={min:5,max:2}]", "clear @s stone[count=\"x\"]", "clear @s stone[damage]", "clear @s stone[!damage]",
    "clear @s stone[damage=1|damage=2,unbreakable]", "clear @s stone[damage~{durability:1}]", "clear @s stone[unbreakable~{}]",
    "clear @s stone[nonsense=1]", "clear @s stone[nonsense~1]", "clear @s stone[damage=", "clear @s stone[damage=1", "clear @s stone[",
    "clear @s stone[]", "clear @s #minecraft:logs[count=1]", "clear @s stone[count~5]", "clear @s stone[ damage = 2 ]", "clear @s *[!count=1|damage]", "clear @a minecraft:stone 2147483648", "kill @a[limit=1]", "tp @e[type=item] ~ ~ ~",
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
    var suggestionBytes = HexFormat.of().parseHex(Files.readString(graphs.resolve("suggestions.hex")).strip());
    var suggestionBuffer = new net.minecraft.network.RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(suggestionBytes), RegistryAccess.EMPTY);
    var suggestions = net.minecraft.network.protocol.game.ClientboundCommandSuggestionsPacket.STREAM_CODEC.decode(suggestionBuffer);
    var texts = suggestions.toSuggestions().getList().stream().map(x -> x.getText()).toList();
    if (suggestionBuffer.isReadable() || suggestions.id() != 7 || !texts.equals(List.of("minecraft:night", "minecraft:noon"))
        || suggestions.toSuggestions().getRange().getStart() != 10 || suggestions.toSuggestions().getRange().getEnd() != 11)
      throw new AssertionError("Suggestion packet differs: " + texts);
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
      + " are refused as not supported yet; Mojang decodes ValiMC's suggestion reply.");
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
      if (path.isEmpty() && child.getName().equals("spark")) {
        if (level < 3 || child.getCommand() == null || !Builder.restricted.contains(child))
          throw new AssertionError("Restricted ValiMC profiler root " + here);
        var expectedNames = Set.of("profiler", "health", "tps", "ping", "tickmonitor", "heapsummary",
          "processes", "ets", "schedulers", "gc", "activity", "help");
        if (!child.getChildren().stream().map(CommandNode::getName).collect(Collectors.toSet()).equals(expectedNames))
          throw new AssertionError("Profiler children differ");
        var profiler = child.getChild("profiler");
        if (!profiler.getChildren().stream().map(CommandNode::getName).collect(Collectors.toSet())
              .equals(Set.of("start", "stop", "cancel", "info", "open")))
          throw new AssertionError("Profiler lifecycle children differ");
        for (var command : List.of(child.getChild("health"), child.getChild("processes"),
              child.getChild("tickmonitor"), profiler.getChild("start"))) {
          if (!(command.getChild("options") instanceof ArgumentCommandNode<Object, ?> options)
              || !(options.getType() instanceof com.mojang.brigadier.arguments.StringArgumentType strings)
              || strings.getType() != com.mojang.brigadier.arguments.StringArgumentType.StringType.GREEDY_PHRASE)
            throw new AssertionError("Profiler option codec differs at " + command.getName());
        }
        count++;
        continue;
      }
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
