import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.core.Direction.Axis;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.*;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.piston.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;

/** Original fixtures invoke actual native piston/world methods and packet codecs. */
public class PistonCollisionOracle {
  private static Field progress,oldProgress;
  private static ThreadLocal<Direction> noclip;
  private static JsonArray cases=new JsonArray();
  private static JsonArray vector(double... values){var a=new JsonArray();for(double v:values)a.add(v);return a;}
  private static PistonMovingBlockEntity entity(BlockPos pos,BlockState moving,BlockState moved,Direction dir,
      boolean extending,boolean source,float value) throws Exception {
    var p=new PistonMovingBlockEntity(pos,moving,moved,dir,extending,source);
    progress.setFloat(p,value);oldProgress.setFloat(p,value);return p;
  }
  private static void probe(BlockState moving,BlockState moved,BlockPos pos,Direction dir,boolean extending,
      boolean source,float value,Direction exclusion,String kind) throws Exception {
    BlockEntity p=switch(kind){case "absent"->null;case "other"->new ChestBlockEntity(pos,Blocks.CHEST.defaultBlockState());
      default->entity(pos,moving,moved,dir,extending,source,value);};
    var world=(BlockGetter)Proxy.newProxyInstance(BlockGetter.class.getClassLoader(),new Class<?>[]{BlockGetter.class},
      (proxy,method,args)->{
        if(method.getName().equals("getBlockEntity")&&args[0].equals(pos))return p;
        throw new AssertionError("Unexpected world query: "+method);
      });
    noclip.set(exclusion);VoxelShape shape;
    try {shape=moving.getCollisionShape(world,pos,CollisionContext.empty());}finally{noclip.remove();}
    var c=new JsonObject();c.addProperty("state",Block.getId(moving));c.add("position",vector(pos.getX(),pos.getY(),pos.getZ()));
    var facts=new JsonObject();facts.addProperty("kind",kind);facts.addProperty("moved",Block.getId(moved));
    facts.addProperty("direction",dir.getName());facts.addProperty("extending",extending);facts.addProperty("source",source);
    facts.addProperty("progress",value);facts.addProperty("exclusion",exclusion==null?"none":exclusion.getName());
    c.add("context",facts);c.add("geometry",CollisionMetadata.geometry(shape));var queries=new JsonArray();
    var worldShape=shape.move(pos.getX(),pos.getY(),pos.getZ());
    for(var axis:Axis.values())for(int sign:new int[]{-1,1}) {
      double[] origin={pos.getX(),pos.getY(),pos.getZ()};double[] lo={origin[0]+.2,origin[1]+.1,origin[2]+.2};
      double[] hi={origin[0]+.8,origin[1]+1.9,origin[2]+.8};int a=axis.ordinal();
      if(sign>0){hi[a]=origin[a]-1.5;lo[a]=hi[a]-.6;}else{lo[a]=origin[a]+2.5;hi[a]=lo[a]+.6;}
      var box=new AABB(lo[0],lo[1],lo[2],hi[0],hi[1],hi[2]);double delta=sign*5.0;
      double result=Shapes.collide(axis,box,List.of(worldShape),delta);var q=new JsonObject();
      q.addProperty("axis",axis.getName());q.addProperty("delta",delta);
      q.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));
      q.addProperty("result_bits",HexFormat.of().toHexDigits(Double.doubleToRawLongBits(result)));queries.add(q);
    }
    c.add("queries",queries);cases.add(c);
  }
  private static String encoded(RegistryAccess.Frozen registries,java.util.function.Consumer<RegistryFriendlyByteBuf> encode) {
    var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
    try{encode.accept(buf);byte[] bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);return HexFormat.of().formatHex(bytes);}
    finally{buf.release();}
  }
  @SuppressWarnings("unchecked")
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    progress=PistonMovingBlockEntity.class.getDeclaredField("progress");progress.setAccessible(true);
    oldProgress=PistonMovingBlockEntity.class.getDeclaredField("progressO");oldProgress.setAccessible(true);
    var f=PistonMovingBlockEntity.class.getDeclaredField("NOCLIP");f.setAccessible(true);noclip=(ThreadLocal<Direction>)f.get(null);
    var catalog=JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonObject();var facts=catalog.getAsJsonObject("piston");
    var pos=new BlockPos(-17,64,17);
    for(var id:facts.getAsJsonArray("moving")) {
      var moving=Block.BLOCK_STATE_REGISTRY.byId(id.getAsInt());
      for(var kind:List.of("absent","other"))probe(moving,Blocks.STONE.defaultBlockState(),pos,Direction.UP,true,false,0,null,kind);
      for(var dir:Direction.values())for(boolean extending:new boolean[]{false,true})for(boolean source:new boolean[]{false,true})
        for(float p:new float[]{0f,0.25f,Math.nextDown(.75f),.75f,Math.nextUp(.75f),Math.nextDown(1f),1f})
          for(var exclusion:new Direction[]{null,dir,dir.getOpposite()})
            for(var moved:List.of(Blocks.STONE.defaultBlockState(),Blocks.PISTON.defaultBlockState(),Blocks.STICKY_PISTON.defaultBlockState()))
              probe(moving,moved,pos,dir,extending,source,p,exclusion,"piston");
    }
    var moving=Blocks.MOVING_PISTON.defaultBlockState();
    for(var base:facts.getAsJsonArray("bases"))for(var dir:Direction.values())for(float p:new float[]{0f,.5f,1f})
      for(var exclusion:new Direction[]{null,dir,dir.getOpposite()})
        probe(moving,Block.BLOCK_STATE_REGISTRY.byId(base.getAsJsonArray().get(0).getAsInt()),pos,dir,false,true,p,exclusion,"piston");
    var cache=BlockBehaviour.BlockStateBase.class.getDeclaredField("cache");cache.setAccessible(true);var grids=new HashSet<String>();int dynamic=0;
    for(var state:Block.BLOCK_STATE_REGISTRY) {
      if(state.getBlock() instanceof MovingPistonBlock)continue;
      var cached=cache.get(state);
      if(cached!=null) {
        var collision=cached.getClass().getDeclaredField("collisionShape");collision.setAccessible(true);
        if(!grids.add(new Gson().toJson(CollisionMetadata.geometry((VoxelShape)collision.get(cached)))))continue;
      }else dynamic++;
      probe(moving,state,pos,Direction.EAST,true,false,.5f,null,"piston");
    }
    if(grids.size()!=330||dynamic!=187)throw new AssertionError("Moved state coverage differs");
    Files.writeString(Path.of(args[1]),new Gson().toJson(cases));
    if(args.length>2) {
      var registries=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();var fixtures=new JsonObject();
      fixtures.addProperty("freeze",encoded(registries,b->ClientboundTickingStatePacket.STREAM_CODEC.encode(b,new ClientboundTickingStatePacket(20f,true))));
      fixtures.addProperty("unfreeze",encoded(registries,b->ClientboundTickingStatePacket.STREAM_CODEC.encode(b,new ClientboundTickingStatePacket(20f,false))));
      fixtures.addProperty("step",encoded(registries,b->ClientboundTickingStepPacket.STREAM_CODEC.encode(b,new ClientboundTickingStepPacket(1))));
      var eventDemos=new JsonArray();var basePos=new BlockPos(0,63,0);
      for(boolean source:new boolean[]{false,true})for(boolean extending:new boolean[]{false,true}) {
        boolean sticky=!source&&!extending;var block=sticky?Blocks.STICKY_PISTON:Blocks.PISTON;
        var base=block.defaultBlockState().setValue(PistonBaseBlock.FACING,Direction.UP).setValue(PistonBaseBlock.EXTENDED,!extending);
        var head=Blocks.PISTON_HEAD.defaultBlockState().setValue(PistonHeadBlock.FACING,Direction.UP)
          .setValue(PistonHeadBlock.TYPE,sticky?net.minecraft.world.level.block.state.properties.PistonType.STICKY:
            net.minecraft.world.level.block.state.properties.PistonType.DEFAULT);
        var setup=new JsonArray();setup.add(Block.getId(base));
        setup.add(extending?(source?0:Block.getId(Blocks.STONE.defaultBlockState())):Block.getId(head));
        setup.add(!extending&&!source?Block.getId(Blocks.STONE.defaultBlockState()):0);
        var event=new ClientboundBlockEventPacket(basePos,block,extending?0:1,1);
        String payload=encoded(registries,b->ClientboundBlockEventPacket.STREAM_CODEC.encode(b,event));
        var d=new JsonObject();d.addProperty("source",source);d.addProperty("extending",extending);d.add("setup",setup);
        d.addProperty("event",payload);d.addProperty("position_y",source?(extending?64:63):(extending?65:64));
        d.addProperty("moved",source?Block.getId(block.defaultBlockState().setValue(PistonBaseBlock.FACING,Direction.UP)):Block.getId(Blocks.STONE.defaultBlockState()));
        d.addProperty("state",Block.getId(moving.setValue(MovingPistonBlock.FACING,Direction.UP)
          .setValue(MovingPistonBlock.TYPE,sticky?net.minecraft.world.level.block.state.properties.PistonType.STICKY:
            net.minecraft.world.level.block.state.properties.PistonType.DEFAULT)));
        eventDemos.add(d);
      }
      fixtures.add("event_demos",eventDemos);Files.writeString(Path.of(args[2]),new Gson().toJson(fixtures));
    }
    System.out.println("PASS: "+cases.size()+" native piston snapshots / "+cases.size()*6+" clips; 330 cached/187 dynamic moved grids.");
  }
}
