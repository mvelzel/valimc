import com.google.gson.*;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.level.biome.*;
import net.minecraft.world.level.levelgen.synth.*;

/** Native climate for the current plains/sea-level63 flat generator, not biome generation. */
public class FlatClimateOracle {
  static Object field(Class<?> owner,String name,Object target)throws Exception {
    Field f=owner.getDeclaredField(name);f.setAccessible(true);return f.get(target);
  }
  public static void main(String[] args)throws Exception {
    var lookup=MiningToolOracle.initialize();var biome=lookup.lookupOrThrow(Registries.BIOME).getOrThrow(Biomes.PLAINS).value();
    var noise=(Noise)field(Biome.class,"TEMPERATURE_NOISE",null);
    if(!biome.hasPrecipitation()||biome.getBaseTemperature()!=.8f)throw new AssertionError("Changed native plains climate");
    for(String key:List.of("offsetX","offsetY","offsetZ"))if((double)field(GradientNoise.class,key,noise)!=0.0)throw new AssertionError("Unexpected temperature-noise offset");
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.addProperty("biome","minecraft:plains");facts.addProperty("sea_level",63);facts.addProperty("temperature",biome.getBaseTemperature());facts.addProperty("permutation",HexFormat.of().formatHex((byte[])field(GradientNoise.class,"perms",noise)));
    var gradients=new JsonArray();var nativeGradients=(Object[])field(GradientNoise.class,"GRADIENT",null);
    for(int i=0;i<12;i++){var pair=new JsonArray();pair.add((int)field(nativeGradients[i].getClass(),"x",nativeGradients[i]));pair.add((int)field(nativeGradients[i].getClass(),"y",nativeGradients[i]));gradients.add(pair);}facts.add("gradients",gradients);
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");
    var temperature=Biome.class.getDeclaredMethod("getHeightAdjustedTemperature",BlockPos.class,int.class);temperature.setAccessible(true);
    var cache=(ThreadLocal<?>)field(Biome.class,"temperatureCache",biome);var rows=new JsonArray();var random=new Random(170418);
    var columns=new ArrayList<int[]>();for(int x:new int[]{-29999999,-16777217,-1024,-1,0,1,1024,16777217,29999999})for(int z:new int[]{-29999999,-1,0,1,29999999})columns.add(new int[]{x,z});
    for(int i=0;i<128;i++)columns.add(new int[]{random.nextInt(59999999)-29999999,random.nextInt(59999999)-29999999});
    for(var column:columns){
      var ys=new ArrayList<Integer>();for(int y:new int[]{-1000000,-64,0,63,64,79,80,81,319,320,321,1024,1000000})ys.add(y);for(int y=580;y<=620;y++)ys.add(y);
      for(int y:ys){
        var pos=new BlockPos(column[0],y,column[1]);((Map<?,?>)cache.get()).clear();
        var row=new JsonArray();row.add(column[0]);row.add(y);row.add(column[1]);row.add((float)temperature.invoke(biome,pos,63));row.add(biome.getPrecipitationAt(pos,63).toString().toLowerCase(Locale.ROOT));rows.add(row);
      }
    }
    Files.writeString(Path.of(args[1]),new Gson().toJson(rows));System.out.println("PASS: "+rows.size()+" native flat-plains temperatures/precipitation, including rain/snow boundaries, far coordinates and altitude. Cache cleared between observations; no biome/world generation.");
  }
}
