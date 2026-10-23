import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.material.*;
import net.minecraft.world.level.storage.*;
import net.minecraft.world.phys.*;

/**
 * Native 26.3 explosion reach (VMC-050a) over supplied scenes: the cells
 * `ServerExplosion.calculateExplodedPositions` breaks for a centre, radius and
 * `LegacyRandomSource` seed, and `getSeenPercent` with the default calculator's
 * damage for boxes around walls. Each scene is every cell of a box (x fastest,
 * then y, then z) as two hex bytes per state; cells outside read as air. With
 * `packet`, the bytes vanilla's `ClientboundExplodePacket` carries between the
 * knockback and the play-sound flag for a small and a large explosion (the
 * default particles, block particles and `GENERIC_EXPLODE`), and full packets.
 * Usage: ExplosionOracle OUT.json | ExplosionOracle packet FACTS.json
 */
public class ExplosionOracle {
  static final int REACH=11;
  private static class ProbeLevel extends ServerLevel {
    Map<BlockPos,BlockState> blocks=new HashMap<>();
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public int getNextEntityId(){return 1;}
    public int getMinY(){return -64;}
    public int getHeight(){return 384;}
    public BlockState getBlockState(BlockPos p){return blocks.getOrDefault(p,Blocks.AIR.defaultBlockState());}
    public FluidState getFluidState(BlockPos p){return getBlockState(p).getFluidState();}
  }
  private static class ProbeEntity extends Entity {
    ProbeEntity(Level world){super(EntityTypes.ITEM,world);}
    protected void defineSynchedData(SynchedEntityData.Builder builder){}
    protected void readAdditionalSaveData(ValueInput in){}
    protected void addAdditionalSaveData(ValueOutput out){}
    public boolean hurtServer(ServerLevel world,DamageSource source,float amount){return false;}
  }
  static sun.misc.Unsafe unsafe;
  static Field field(Class<?> c,String name)throws Exception{var f=c.getDeclaredField(name);f.setAccessible(true);return f;}
  static JsonArray vector(double... values){var a=new JsonArray();for(double v:values)a.add(v);return a;}
  static JsonArray cell(BlockPos p){var a=new JsonArray();a.add(p.getX());a.add(p.getY());a.add(p.getZ());return a;}
  static void put(Object target,Class<?> c,String name,Object value)throws Exception{
    var f=c.getDeclaredField(name);unsafe.putObject(target,unsafe.objectFieldOffset(f),value);
  }

  /** A scene: every cell of the box around `origin`, by `pick(x, y, z)`. */
  interface Pick{BlockState at(int x,int y,int z);}
  static Map<BlockPos,BlockState> scene(BlockPos origin,Pick pick,JsonObject scenes,String name){
    var blocks=new HashMap<BlockPos,BlockState>();var hex=new StringBuilder();
    for(int z=-REACH;z<=REACH;z++)for(int y=-REACH;y<=REACH;y++)for(int x=-REACH;x<=REACH;x++){
      var p=origin.offset(x,y,z);var state=pick.at(p.getX(),p.getY(),p.getZ());
      if(p.getY()<-64||p.getY()>=320)state=Blocks.VOID_AIR.defaultBlockState();
      blocks.put(p,state);hex.append(String.format(Locale.ROOT,"%04x",Block.getId(state)));
    }
    var out=new JsonObject();out.add("min",cell(origin.offset(-REACH,-REACH,-REACH)));
    out.addProperty("size",2*REACH+1);out.addProperty("states",hex.toString());scenes.add(name,out);
    return blocks;
  }

  static byte[] encode(Object packet){
    var access=net.minecraft.core.RegistryAccess.fromRegistryOfRegistries(net.minecraft.core.registries.BuiltInRegistries.REGISTRY);
    var buffer=new net.minecraft.network.RegistryFriendlyByteBuf(io.netty.buffer.Unpooled.buffer(),access);
    try{net.minecraft.network.protocol.game.GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new net.minecraft.network.RegistryFriendlyByteBuf(b,access)).codec()
          .encode(buffer,(net.minecraft.network.protocol.Packet)packet);
      var bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);return bytes;}finally{buffer.release();}
  }
  static Object explodePacket(Vec3 center,float radius,int count,Optional<Vec3> knockback,boolean small)throws Exception{
    var particles=field(Level.class,"DEFAULT_EXPLOSION_BLOCK_PARTICLES").get(null);
    @SuppressWarnings("unchecked") var list=(net.minecraft.util.random.WeightedList<net.minecraft.core.particles.ExplosionParticleInfo>)particles;
    return new net.minecraft.network.protocol.game.ClientboundExplodePacket(center,radius,count,knockback,
        small?net.minecraft.core.particles.ParticleTypes.EXPLOSION:net.minecraft.core.particles.ParticleTypes.EXPLOSION_EMITTER,
        net.minecraft.sounds.SoundEvents.GENERIC_EXPLODE,list,true);
  }
  static void packets(String path)throws Exception{
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    var hex=HexFormat.of();
    for(boolean small:new boolean[]{true,false}){
      var bytes=encode(explodePacket(Vec3.ZERO,4.0f,0,Optional.empty(),small));
      // Packet id, centre, radius, count, absent knockback; the play-sound flag ends it.
      int prefix=1+24+4+4+1;
      if(bytes[prefix-1]!=0||bytes[bytes.length-1]!=1)throw new AssertionError("Unexpected explode packet layout");
      out.addProperty(small?"small":"large",hex.formatHex(Arrays.copyOfRange(bytes,prefix,bytes.length-1)));
    }
    out.addProperty("id",encode(explodePacket(Vec3.ZERO,4.0f,0,Optional.empty(),true))[0]);
    var cases=new JsonArray();
    for(var c:new double[][]{{.5,64.06125,.5,4,23,0,0,0,0},{-1e7+.25,-63.5,29999999.5,1.5,0,1,.25,-.75,3.5},{12.3,100,-4.2,6,312,1,0,0,0}}){
      var knockback=c[5]==1?Optional.of(new Vec3(c[6],c[7],c[8])):Optional.<Vec3>empty();
      var row=new JsonObject();row.add("center",vector(c[0],c[1],c[2]));row.addProperty("radius",(float)c[3]);row.addProperty("count",(int)c[4]);
      if(knockback.isPresent())row.add("knockback",vector(c[6],c[7],c[8]));
      row.addProperty("wire",hex.formatHex(encode(explodePacket(new Vec3(c[0],c[1],c[2]),(float)c[3],(int)c[4],knockback,c[3]<2))));cases.add(row);
    }
    out.add("cases",cases);
    Files.writeString(Path.of(path),new GsonBuilder().setPrettyPrinting().create().toJson(out)+"\n");
    System.out.println("PASS: native explode packet particle, sound and block-particle bytes for small and large explosions and "+cases.size()+" full packets.");
  }

  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    if(args[0].equals("packet")){packets(args[1]);return;}
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);unsafe=(sun.misc.Unsafe)f.get(null);
    var world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);world.blocks=new HashMap<>();
    var explode=ServerExplosion.class.getDeclaredMethod("calculateExplodedPositions");explode.setAccessible(true);
    var scenes=new JsonObject();var craters=new JsonArray();var exposures=new JsonArray();
    var stone=Blocks.STONE.defaultBlockState();var air=Blocks.AIR.defaultBlockState();
    var mixedPalette=List.of(Blocks.STONE,Blocks.DIRT,Blocks.OAK_PLANKS,Blocks.OBSIDIAN,Blocks.GLASS,Blocks.WATER,
        Blocks.SAND,Blocks.COBBLESTONE,Blocks.AIR,Blocks.AIR,Blocks.AIR,Blocks.BEDROCK,Blocks.OAK_LEAVES,Blocks.IRON_BARS);
    var picker=new Random(42);var mixed=new HashMap<BlockPos,BlockState>();
    record Scene(String name,BlockPos origin,Pick pick){}
    var list=List.of(
      new Scene("flat",new BlockPos(0,64,0),(x,y,z)->y<64?stone:air),
      new Scene("mixed",new BlockPos(0,64,0),(x,y,z)->mixed.computeIfAbsent(new BlockPos(x,y,z),
          p->mixedPalette.get(picker.nextInt(mixedPalette.size())).defaultBlockState())),
      new Scene("pool",new BlockPos(0,64,0),(x,y,z)->y<64?stone:y<66?Blocks.WATER.defaultBlockState():air),
      new Scene("bottom",new BlockPos(0,-62,0),(x,y,z)->y==-64?Blocks.BEDROCK.defaultBlockState():y<-62?stone:air),
      new Scene("top",new BlockPos(0,318,0),(x,y,z)->y<318?stone:air),
      new Scene("walls",new BlockPos(0,64,0),(x,y,z)->y<64?stone:(x==2&&y<66)||(z==-3&&x>=-1)?Blocks.OBSIDIAN.defaultBlockState():
          (x==-2&&z>=0)?Blocks.GLASS.defaultBlockState():(x==-3&&z<0&&y==64)?Blocks.OAK_SLAB.defaultBlockState():air));
    var centres=Map.of("flat",new double[]{.5,64.06125,.5},"mixed",new double[]{.5,64.5,.5},"pool",new double[]{.5,64.06125,.5},
        "bottom",new double[]{.5,-62.93875,.5},"top",new double[]{.5,318.06125,.5},"walls",new double[]{.5,64.06125,.5});
    for(var s:list){
      world.blocks=scene(s.origin(),s.pick(),scenes,s.name());var c=centres.get(s.name());var center=new Vec3(c[0],c[1],c[2]);
      for(float radius:new float[]{1.0f,3.0f,4.0f,6.0f})for(long seed=0;seed<(radius==4.0f?6:2);seed++){
        put(world,Level.class,"random",RandomSource.create(seed));
        var e=(ServerExplosion)unsafe.allocateInstance(ServerExplosion.class);
        put(e,ServerExplosion.class,"level",world);put(e,ServerExplosion.class,"center",center);
        unsafe.putFloat(e,unsafe.objectFieldOffset(ServerExplosion.class.getDeclaredField("radius")),radius);
        put(e,ServerExplosion.class,"damageCalculator",new ExplosionDamageCalculator());
        put(e,ServerExplosion.class,"blockInteraction",Explosion.BlockInteraction.DESTROY_WITH_DECAY);
        @SuppressWarnings("unchecked") var cells=new ArrayList<BlockPos>((List<BlockPos>)explode.invoke(e));
        cells.sort(Comparator.<BlockPos>comparingInt(p->p.getX()).thenComparingInt(p->p.getY()).thenComparingInt(p->p.getZ()));
        var row=new JsonObject();row.addProperty("scene",s.name());row.add("center",vector(c));row.addProperty("radius",radius);
        row.addProperty("seed",seed);var out=new JsonArray();for(var p:cells)out.add(cell(p));row.add("cells",out);craters.add(row);
        if(radius==4.0f&&seed==0&&(s.name().equals("walls")||s.name().equals("flat")||s.name().equals("mixed")))
          for(double[] size:new double[][]{{.6,1.8},{.25,.25},{.98,.98}})
            for(double[] at:new double[][]{{3.5,64,.5},{-1.5,64,.5},{-3.5,64,-1.5},{.5,64,-4.2},{1.2,64.3,1.7},{.5,65.2,.5},{-.5,64,2.5},{4.6,64,4.1},{.5,64.06125,.5}}){
              var entity=new ProbeEntity(world);var pos=new Vec3(at[0],at[1],at[2]);
              field(Entity.class,"position").set(entity,pos);
              var box=new AABB(at[0]-size[0]/2,at[1],at[2]-size[0]/2,at[0]+size[0]/2,at[1]+size[1],at[2]+size[0]/2);
              field(Entity.class,"bb").set(entity,box);
              float seen=ServerExplosion.getSeenPercent(center,entity);
              float damage=new ExplosionDamageCalculator().getEntityDamageAmount(e,entity,seen);
              var x=new JsonObject();x.addProperty("scene",s.name());x.add("center",vector(c));x.addProperty("radius",radius);
              x.add("position",vector(at));x.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));
              x.addProperty("seen",seen);x.addProperty("damage",damage);exposures.add(x);
            }
      }
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.add("scenes",scenes);out.add("craters",craters);out.add("exposures",exposures);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+craters.size()+" native explosion craters over "+scenes.size()+" scenes and "+exposures.size()+
        " exposure/damage cases; cells outside a scene read as air.");
  }
}
