import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction.Axis;
import net.minecraft.core.Holder;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.tags.EntityTypeTags;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.*;
import sun.misc.Unsafe;
import java.nio.file.*;
import java.util.*;

/** Constructor-free entities exercise the actual native method; no world/server runs. */
public class PowderSnowCollisionOracle {
  private static class ProbePlayer extends Player {
    ItemStack boots;
    private ProbePlayer(){super(null,null);}
    public GameType gameMode(){return GameType.CREATIVE;}
    public ItemStack getItemBySlot(EquipmentSlot slot){
      if(slot!=EquipmentSlot.FEET)throw new AssertionError("Unexpected equipment query");
      return boots;
    }
  }
  private static class Context extends EntityCollisionContext {
    Context(double bottom,boolean descending,boolean placement,Entity entity){
      super(descending,placement,bottom,ItemStack.EMPTY,false,entity);
    }
  }
  private static Unsafe unsafe;
  private static java.lang.reflect.Field type;
  private static Entity entity(String kind) throws Exception {
    if(kind.equals("absent"))return null;
    Entity e;EntityType<?> entityType;
    if(kind.startsWith("living_")) {
      var p=(ProbePlayer)unsafe.allocateInstance(ProbePlayer.class);
      p.boots=switch(kind){case "living_leather"->new ItemStack(Items.LEATHER_BOOTS);
        case "living_diamond"->new ItemStack(Items.DIAMOND_BOOTS);default->ItemStack.EMPTY;};
      e=p;entityType=EntityTypes.PLAYER;
    } else if(kind.equals("falling_block")) {
      e=(Entity)unsafe.allocateInstance(FallingBlockEntity.class);entityType=EntityTypes.FALLING_BLOCK;
    } else {
      e=(Entity)unsafe.allocateInstance(ItemEntity.class);
      entityType=kind.equals("tagged_nonliving")?EntityTypes.FOX:EntityTypes.ITEM;
    }
    type.set(e,entityType);return e;
  }
  private static JsonArray vector(double... v){var a=new JsonArray();for(double x:v)a.add(x);return a;}
  private static JsonObject facts(String kind,double bottom,boolean descending,boolean placement,Entity e) {
    var c=new JsonObject();c.addProperty("kind",kind);c.addProperty("bottom",bottom);
    c.addProperty("descending",descending);c.addProperty("placement",placement);
    c.addProperty("entity_present",e!=null);c.addProperty("fall_distance",e==null?0.0:e.fallDistance);
    c.addProperty("falling_block",e instanceof FallingBlockEntity);
    c.addProperty("walkable",e!=null&&PowderSnowBlock.canEntityWalkOnPowderSnow(e));return c;
  }
  private static JsonObject probe(BlockPos pos,CollisionContext ctx,JsonObject facts) throws Exception {
    var shape=Blocks.POWDER_SNOW.defaultBlockState().getCollisionShape(EmptyBlockGetter.INSTANCE,pos,ctx);
    var worldShape=shape.move(pos.getX(),pos.getY(),pos.getZ());var c=new JsonObject();
    c.add("position",vector(pos.getX(),pos.getY(),pos.getZ()));c.add("context",facts);
    c.add("geometry",BlockFactsOracle.geometry(shape));var queries=new JsonArray();
    for(var axis:Axis.values())for(int direction:new int[]{-1,1}) {
      double[] origin={pos.getX(),pos.getY(),pos.getZ()};
      double[] lo={origin[0]+0.2,origin[1]+0.1,origin[2]+0.2};
      double[] hi={origin[0]+0.8,origin[1]+1.9,origin[2]+0.8};int a=axis.ordinal();
      if(direction>0){hi[a]=origin[a]-0.15;lo[a]=hi[a]-0.6;}
      else{lo[a]=origin[a]+1.15;hi[a]=lo[a]+0.6;}
      var box=new AABB(lo[0],lo[1],lo[2],hi[0],hi[1],hi[2]);double delta=direction*4.0;
      double result=Shapes.collide(axis,box,List.of(worldShape),delta);var q=new JsonObject();
      q.addProperty("axis",axis.getName());q.addProperty("delta",delta);
      q.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));
      q.addProperty("result_bits",HexFormat.of().toHexDigits(Double.doubleToRawLongBits(result)));queries.add(q);
    }
    c.add("queries",queries);return c;
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var f=Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);unsafe=(Unsafe)f.get(null);
    type=Entity.class.getDeclaredField("type");type.setAccessible(true);
    // Controlled membership tests the real native tag branch, not base-pack tag loading.
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var t:List.of(EntityTypes.PLAYER,EntityTypes.ITEM,EntityTypes.FALLING_BLOCK,EntityTypes.FOX))
      bind.invoke(t.builtInRegistryHolder(),t==EntityTypes.FOX?List.of(EntityTypeTags.POWDER_SNOW_WALKABLE_MOBS):List.of());
    var cases=new JsonArray();
    for(int y:new int[]{-1000000,-384,0,64,320,1000000}) {
      var pos=new BlockPos(-17,y,17);var empty=new JsonObject();empty.addProperty("kind","empty");
      cases.add(probe(pos,CollisionContext.empty(),empty));double threshold=y+1.0-(double)1.0e-5f;
      for(var kind:List.of("absent","nonliving","tagged_nonliving","living_bare","living_leather","living_diamond","falling_block")) {
        var e=entity(kind);
        boolean walks=e!=null&&PowderSnowBlock.canEntityWalkOnPowderSnow(e);
        if(walks!=(kind.equals("tagged_nonliving")||kind.equals("living_leather")))
          throw new AssertionError("Native equipment/tag fixture mismatch: "+kind);
        for(double fall:new double[]{-1.0,0.0,Math.nextDown(2.5),2.5,Math.nextUp(2.5),10.0}) {
          if(e!=null)e.fallDistance=fall;
          for(double bottom:new double[]{y-1.0,y+0.5,y+1.0,y+2.0,Math.nextDown(threshold),threshold,Math.nextUp(threshold)})
            for(boolean descending:new boolean[]{false,true})for(boolean placement:new boolean[]{false,true})
              cases.add(probe(pos,new Context(bottom,descending,placement,e),facts(kind,bottom,descending,placement,e)));
        }
      }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native powder-snow contexts / "+cases.size()*6+" clipping queries.");
  }
}
