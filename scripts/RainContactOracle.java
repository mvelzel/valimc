import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.level.biome.*;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.phys.AABB;

/** Actual Level precipitation and Entity two-point rain logic; controlled sky/height/biome observations. */
public class RainContactOracle {
  static class World extends FireContactOracle.World {
    boolean wet,feetSky,headSky;int surface,feetY;Holder<Biome> biome;
    public boolean isRaining(){return wet;}
    public boolean canSeeSky(BlockPos p){return p.getY()==feetY?feetSky:headSky;}
    public BlockPos getHeightmapPos(Heightmap.Types type,BlockPos p){if(type!=Heightmap.Types.MOTION_BLOCKING)throw new AssertionError(type);return new BlockPos(p.getX(),surface,p.getZ());}
    public Holder<Biome> getBiome(BlockPos p){return biome;}
    public int getSeaLevel(){return 63;}
  }
  static class Body extends FireContactOracle.Body {
    BlockPos feet;
    public BlockPos blockPosition(){return feet;}
  }
  public static void main(String[] args)throws Exception{
    var lookup=MiningToolOracle.initialize();var biomes=lookup.lookupOrThrow(Registries.BIOME);
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var u=(sun.misc.Unsafe)field.get(null);
    var world=(World)u.allocateInstance(World.class);var body=(Body)u.allocateInstance(Body.class);body.world=world;
    var rain=Entity.class.getDeclaredMethod("isInRain");rain.setAccessible(true);var rows=new JsonArray();
    for(var key:List.of(Biomes.PLAINS,Biomes.SNOWY_PLAINS,Biomes.DESERT,Biomes.SAVANNA,Biomes.TAIGA,Biomes.FROZEN_PEAKS)){
      world.biome=biomes.getOrThrow(key);
      for(boolean wet:new boolean[]{false,true})for(boolean feetSky:new boolean[]{false,true})for(boolean headSky:new boolean[]{false,true})
        for(int surface:new int[]{-64,64,65,66,319,320})for(double y:new double[]{-64,63.99999,64,64.2,318,319,1024})for(double height:new double[]{(double)1.8f,(double)1.5f,(double).6f}){
          world.wet=wet;world.feetSky=feetSky;world.headSky=headSky;world.surface=surface;body.feet=BlockPos.containing(.5,y,.5);world.feetY=body.feet.getY();
          var box=new AABB(.2,y,.2,.8,y+height,.8);FireContactOracle.field(Entity.class,"bb").set(body,box);var head=BlockPos.containing(0,box.maxY,0);
          boolean result=(boolean)rain.invoke(body);var row=new JsonObject();row.addProperty("biome",key.identifier().getPath());row.addProperty("wet",wet);row.addProperty("feet_sky",feetSky);row.addProperty("head_sky",head.getY()==world.feetY?feetSky:headSky);row.addProperty("surface",surface);row.addProperty("feet_y",body.feet.getY());row.addProperty("head_y",head.getY());
          row.addProperty("feet_precipitation",world.biome.value().getPrecipitationAt(body.feet,63).toString().toLowerCase(Locale.ROOT));row.addProperty("head_precipitation",world.biome.value().getPrecipitationAt(head,63).toString().toLowerCase(Locale.ROOT));row.addProperty("exposed",result);rows.add(row);
        }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));System.out.println("PASS: "+rows.size()+" native two-point rain exposure contexts, six biomes, roof/sky boundaries, poses and altitude. Sky/height/biome acquisition controlled; climate noise not reimplemented.");
  }
}
