import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.LiquidBlock;
import net.minecraft.world.level.block.state.BlockState;

/**
 * Per block state, the properties decoration reads (VMC-025), as vanilla's own methods
 * answer them: bit 0 `isAir`, 1 `canBeReplaced()`, 2 `isSolid` (legacy solid), 3
 * `hasBlockEntity`, 4 a post-processing position at the block itself (`getPostProcessPos`),
 * 5..10 a sturdy full face (`isFaceSturdy`) down, up, north, south, west, east, 11 a liquid
 * block, 12 `liquid()` (legacy liquid), 13 a double plant (`DoublePlantBlock` or a subclass),
 * 14 a mossy carpet (`MossyCarpetBlock`), 15 a post-processing position above the block
 * (soul sand, magma: bubble columns), 16 `isSolidRender`, 17..22 a full collision face down, up,
 * north, south, west, east (`Block.isFaceFull` of the collision shape; mossy carpets attach to
 * it or to a sturdy face), 23 `isCollisionShapeFullBlock`, 24..29 a full face occlusion shape
 * (`getFaceOcclusionShape` neither empty nor partial: underwater magma's visibility) down, up,
 * north, south, west, east, 30 a `LiquidBlockContainer`, 31 a `SimpleWaterloggedBlock` (structure
 * templates fill them with water, VMC-025c). Every question runs against a level that fails on
 * any read, so none of them depends on the neighbourhood; a state whose sturdiness reads the
 * level (a moving piston's block entity) is listed as excluded, without sturdy faces. Output:
 * the flags, four bytes per state in hex; and the states fire can burn (`FireBlock.canBurn`:
 * ignite odds above zero, none while waterlogged) as runs of state ids, which fire's shape
 * reads of its six neighbours (VMC-026a).
 */
public class WorldgenBlocksOracle {
  static final BlockPos ORIGIN = new BlockPos(0, 64, 0);

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var level = (BlockGetter) Proxy.newProxyInstance(WorldgenBlocksOracle.class.getClassLoader(),
        new Class<?>[] {BlockGetter.class}, (proxy, method, a) -> switch (method.getName()) {
          case "getMinY" -> -64;
          case "getHeight" -> a == null ? 384 : null;
          case "hashCode" -> System.identityHashCode(proxy);
          case "equals" -> proxy == a[0];
          case "toString" -> "WorldgenBlocksProbe";
          default -> throw new IllegalStateException("level read: " + method.getName());
        });
    int count = Block.BLOCK_STATE_REGISTRY.size();
    var hex = new StringBuilder(count * 8);
    int[] totals = new int[32];
    var excluded = new TreeSet<String>();
    for (int id = 0; id < count; id++) {
      BlockState state = Block.BLOCK_STATE_REGISTRY.byId(id);
      int flags = 0;
      if (state.isAir()) flags |= 1;
      if (state.canBeReplaced()) flags |= 2;
      if (state.isSolid()) flags |= 4;
      if (state.hasBlockEntity()) flags |= 8;
      var post = state.getPostProcessPos(level, ORIGIN);
      if (post != null) {
        if (post.equals(ORIGIN)) flags |= 16;
        else if (post.equals(ORIGIN.above())) flags |= 32768;
        else throw new IllegalStateException("post-processing elsewhere: " + state);
      }
      var directions = Direction.values();
      try {
        for (int d = 0; d < 6; d++) if (state.isFaceSturdy(level, ORIGIN, directions[d])) flags |= 32 << d;
      } catch (IllegalStateException e) {
        flags &= ~(63 << 5);
        excluded.add(BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString());
      }
      try {
        var collision = state.getCollisionShape(level, ORIGIN);
        for (int d = 0; d < 6; d++) if (Block.isFaceFull(collision, directions[d])) flags |= 1 << (17 + d);
      } catch (IllegalStateException e) {
        excluded.add(BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString());
      }
      if (state.getBlock() instanceof LiquidBlock) flags |= 2048;
      if (state.liquid()) flags |= 4096;
      if (state.getBlock() instanceof net.minecraft.world.level.block.DoublePlantBlock) flags |= 8192;
      if (state.getBlock() instanceof net.minecraft.world.level.block.MossyCarpetBlock) flags |= 16384;
      if (state.isSolidRender()) flags |= 1 << 16;
      try {
        if (state.isCollisionShapeFullBlock(level, ORIGIN)) flags |= 1 << 23;
      } catch (IllegalStateException e) {
        excluded.add(BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString());
      }
      for (int d = 0; d < 6; d++) {
        var occlusion = state.getFaceOcclusionShape(directions[d]);
        if (occlusion != net.minecraft.world.phys.shapes.Shapes.empty() && Block.isShapeFullBlock(occlusion)) flags |= 1 << (24 + d);
      }
      if (state.getBlock() instanceof net.minecraft.world.level.block.LiquidBlockContainer) flags |= 1 << 30;
      if (state.getBlock() instanceof net.minecraft.world.level.block.SimpleWaterloggedBlock) flags |= 1 << 31;
      for (int b = 0; b < 32; b++) if ((flags & (1 << b)) != 0) totals[b]++;
      hex.append(String.format("%08x", flags));
    }
    var out = new JsonObject();
    out.addProperty("version", "26.3");
    out.addProperty("data_version", 5023);
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.addProperty("state_count", count);
    out.add("bits", new Gson().toJsonTree(List.of("air", "replaceable", "solid", "block_entity", "post_process",
        "sturdy_down", "sturdy_up", "sturdy_north", "sturdy_south", "sturdy_west", "sturdy_east", "liquid_block",
        "liquid", "double_plant", "mossy_carpet", "post_process_above", "solid_render", "collision_down",
        "collision_up", "collision_north", "collision_south", "collision_west", "collision_east", "full_collision",
        "occludes_down", "occludes_up", "occludes_north", "occludes_south", "occludes_west", "occludes_east",
        "liquid_container", "simple_waterlogged")));
    out.addProperty("flags", hex.toString());
    var canBurn = net.minecraft.world.level.block.FireBlock.class.getDeclaredMethod("canBurn", BlockState.class);
    canBurn.setAccessible(true);
    var flammable = new JsonArray();
    int burning = 0;
    for (int id = 0; id < count; id++) {
      if (!(boolean) canBurn.invoke(net.minecraft.world.level.block.Blocks.FIRE, Block.BLOCK_STATE_REGISTRY.byId(id))) continue;
      burning++;
      int last = flammable.size() - 1;
      if (last >= 0 && flammable.get(last).getAsJsonArray().get(1).getAsInt() == id - 1) {
        flammable.get(last).getAsJsonArray().set(1, new JsonPrimitive(id));
      } else {
        var run = new JsonArray();
        run.add(id);
        run.add(id);
        flammable.add(run);
      }
    }
    out.add("flammable", flammable);
    out.add("excluded", new Gson().toJsonTree(excluded));
    Files.writeString(Path.of(args[0]), new Gson().toJson(out) + "\n");
    System.out.println("PASS: worldgen flags of " + count + " block states " + Arrays.toString(totals) + ", " + burning
        + " flammable; excluded " + excluded);
  }
}
