import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.animal.fish.Pufferfish;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.*;

/** Original native dimension changes over full and partial collision scenes. */
public class PufferResizeOracle {
  record Cell(int x, int y, int z, BlockState state) {}
  record Scene(String name, List<Cell> cells) {}
  static Cell cell(int x, int y, int z, BlockState state) { return new Cell(x, y, z, state); }
  static Scene scene(String name, Cell... cells) { return new Scene(name, List.of(cells)); }
  static JsonArray point(net.minecraft.world.phys.Vec3 p) {
    var row = new JsonArray(); for (double v : new double[] {p.x, p.y, p.z}) row.add(NaturalSpawnOracle.bits(v)); return row;
  }
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    registries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE, lookup)); BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(lookup, access, new net.minecraft.world.damagesource.DamageSources(access));
    var stone = Blocks.STONE.defaultBlockState();
    var scenes = List.of(scene("air"), scene("floor", cell(0,63,0,stone)),
      scene("ceiling", cell(0,65,0,stone)), scene("east",cell(1,64,0,stone)),
      scene("west",cell(-1,64,0,stone)), scene("north",cell(0,64,-1,stone)),
      scene("south",cell(0,64,1,stone)), scene("corner",cell(1,64,0,stone),cell(0,64,1,stone)),
      scene("floor_wall",cell(0,63,0,stone),cell(1,64,0,stone)),
      scene("slab",cell(1,64,0,Blocks.OAK_SLAB.defaultBlockState())),
      scene("stairs",cell(1,64,0,Blocks.OAK_STAIRS.defaultBlockState().setValue(StairBlock.FACING,Direction.WEST))),
      scene("fence",cell(1,64,0,Blocks.OAK_FENCE.defaultBlockState())),
      scene("trapdoor",cell(1,64,0,Blocks.OAK_TRAPDOOR.defaultBlockState().setValue(TrapDoorBlock.OPEN,true).setValue(TrapDoorBlock.FACING,Direction.WEST))),
      scene("snow",cell(0,64,0,Blocks.SNOW.defaultBlockState().setValue(SnowLayerBlock.LAYERS,4))),
      scene("powder_snow",cell(0,64,0,Blocks.POWDER_SNOW.defaultBlockState())),
      scene("scaffolding",cell(0,64,0,Blocks.SCAFFOLDING.defaultBlockState())),
      scene("honey",cell(1,64,0,Blocks.HONEY_BLOCK.defaultBlockState())),
      scene("wall_gap",cell(0,64,0,Blocks.COBBLESTONE_WALL.defaultBlockState()),cell(1,64,0,Blocks.COBBLESTONE_WALL.defaultBlockState())),
      scene("short_gap",cell(0,62,0,stone),cell(0,63,0,Blocks.OAK_SLAB.defaultBlockState().setValue(SlabBlock.TYPE,SlabType.TOP))));
    var cases = new JsonArray();
    for (boolean border : List.of(false,true)) for (var scene : scenes) for (int old = 0; old < 2; old++)
      for (double x : new double[] {.2,.5,.8,1.0}) for (double y : new double[] {63.0,64.0,64.2,64.5,64.6,65.0})
        for (double z : new double[] {.2,.5,.8}) {
          level.border.setCenter(.5,.5); level.border.setSize(border ? 1 : 59999968);
          level.blocks.clear(); for (var c : scene.cells) level.blocks.put(new BlockPos(c.x,c.y,c.z),c.state);
          var fish = (Pufferfish)MobAiOracle.mob("minecraft:pufferfish",level);
          fish.setPuffState(old); fish.setPos(x,y,z);
          if (!level.noCollision(fish,fish.getBoundingBox())) continue;
          MobAiOracle.field(Entity.class,"firstTick").setBoolean(fish,false);
          var row = new JsonObject(); row.addProperty("scene",scene.name); row.addProperty("old",old);
          if (border) {
            var bounds = new JsonArray(); bounds.add(0.0);bounds.add(0.0);bounds.add(1.0);bounds.add(1.0);row.add("border",bounds);
          }
          row.add("before",point(fish.position())); var cells = new JsonArray();
          for (var c : scene.cells) { var a = new JsonArray(); a.add(c.x);a.add(c.y);a.add(c.z);a.add(Block.getId(c.state));cells.add(a); }
          row.add("cells",cells); fish.setPuffState(old+1);
          row.add("after",point(fish.position())); row.add("dimensions",AnimalOracle.dimensions(fish)); cases.add(row);
        }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(cases)+"\n");
    System.out.println("PASS: native pufferfish collision-resize cases: "+cases.size());
  }
}
