import com.google.gson.*;
import java.io.ByteArrayOutputStream;
import java.nio.file.*;
import java.util.*;
import io.netty.buffer.Unpooled;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.game.ServerboundUseItemOnPacket;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.BlockTags;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.*;
import net.minecraft.world.item.context.BlockPlaceContext;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.level.block.state.properties.SlabType;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.*;

/** Original observations of placement candidates, not final permission/collision or callbacks. */
public class PlacementOracle {
  static class ProbeLevel extends ServerLevel {
    BlockPos clickedPos; BlockState clicked, adjacent;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0,null,false);}
    public BlockState getBlockState(BlockPos pos){return pos.equals(clickedPos)?clicked:adjacent;}
    public FluidState getFluidState(BlockPos pos){return getBlockState(pos).getFluidState();}
  }
  static class Context extends BlockPlaceContext {
    Context(Level level, ItemStack stack, BlockHitResult hit){super(level,null,InteractionHand.MAIN_HAND,stack,hit);}
  }
  static Class<?> owner(Class<?> type, String name, Class<?>... params)throws Exception{
    for(var c=type;c!=null;c=c.getSuperclass())try{return c.getDeclaredMethod(name,params).getDeclaringClass();}catch(NoSuchMethodException ignored){}
    throw new NoSuchMethodException(name);
  }
  static JsonArray position(BlockPos pos){return new Gson().toJsonTree(List.of(pos.getX(),pos.getY(),pos.getZ())).getAsJsonArray();}
  static Context context(ProbeLevel level, Item item, Direction face, double y){
    var pos=level.clickedPos;
    return new Context(level,new ItemStack(item),new BlockHitResult(new Vec3(pos.getX()+.5,pos.getY()+y,pos.getZ()+.5),face,pos,false));
  }
  static void observe(JsonArray cases, ProbeLevel level, Item item, BlockState clicked, BlockState adjacent, Direction face, double y, BlockPos pos){
    level.clickedPos=pos;level.clicked=clicked;level.adjacent=adjacent;
    var context=context(level,item,face,y);boolean canPlace=context.canPlace();
    var placed=canPlace?((BlockItem)item).getBlock().getStateForPlacement(context):null;
    var row=new JsonArray();row.add(BuiltInRegistries.ITEM.getId(item));row.add(Block.getId(clicked));row.add(Block.getId(adjacent));row.add(face.get3DDataValue());row.add(y);row.add(position(pos));
    row.add(context.replacingClickedOnBlock());row.add(canPlace);row.add(position(context.getClickedPos()));row.add(placed==null?-1:Block.getId(placed));cases.add(row);
  }
  public static void main(String[] args)throws Exception{
    MiningToolOracle.initialize();var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var level=(ProbeLevel)((sun.misc.Unsafe)field.get(null)).allocateInstance(ProbeLevel.class);
    level.clickedPos=BlockPos.ZERO;level.adjacent=Blocks.AIR.defaultBlockState();
    var plain=new JsonObject();
    for(var block:List.of(Blocks.STONE,Blocks.DIRT,Blocks.COBBLESTONE,Blocks.OAK_PLANKS,Blocks.GLASS)){
      if(owner(block.getClass(),"getStateForPlacement",BlockPlaceContext.class)!=Block.class||block.defaultBlockState().canBeReplaced()||block.asItem().getClass()!=BlockItem.class)throw new AssertionError("Plain placement needs context: "+block);
      plain.addProperty(Integer.toString(BuiltInRegistries.ITEM.getId(block.asItem())),Block.getId(block.defaultBlockState()));
    }
    var slabs=new JsonArray();var slabItems=new ArrayList<Item>();
    for(var block:BuiltInRegistries.BLOCK)if(block.builtInRegistryHolder().is(BlockTags.SLABS)){
      if(owner(block.getClass(),"getStateForPlacement",BlockPlaceContext.class)!=SlabBlock.class||owner(block.getClass(),"canBeReplaced",BlockState.class,BlockPlaceContext.class)!=SlabBlock.class||block.asItem().getClass()!=BlockItem.class)throw new AssertionError("Specialized slab placement: "+block);
      var row=new JsonObject();row.addProperty("item",BuiltInRegistries.ITEM.getId(block.asItem()));var states=new JsonArray();
      for(var type:List.of(SlabType.TOP,SlabType.BOTTOM,SlabType.DOUBLE))for(boolean wet:new boolean[]{true,false})states.add(Block.getId(block.defaultBlockState().setValue(SlabBlock.TYPE,type).setValue(SlabBlock.WATERLOGGED,wet)));
      row.add("states",states);slabs.add(row);slabItems.add(block.asItem());
    }
    if(slabs.size()!=101)throw new AssertionError("Changed slab tag");
    var flags=new ByteArrayOutputStream();var unsupported=new TreeSet<String>();var cases=new JsonArray();
    for(var state:Block.BLOCK_STATE_REGISTRY){
      if(Block.getId(state)!=flags.size())throw new AssertionError("Noncontiguous states");
      var method=owner(state.getBlock().getClass(),"canBeReplaced",BlockState.class,BlockPlaceContext.class);
      int flag=0;
      if(method==SlabBlock.class)flag=3;
      else if(method==BlockBehaviour.class||method==SnowLayerBlock.class){
        level.clicked=state;var ctx=context(level,Items.STONE,Direction.UP,.5);flag=ctx.replacingClickedOnBlock()?2:1;
        if(method==BlockBehaviour.class && (flag==2)!=state.canBeReplaced())throw new AssertionError("Plain same-item replacement needs admission");
      }else unsupported.add(method.getSimpleName());
      flags.write(flag);
      if(flag!=0)for(var item:List.of(Items.STONE,Items.OAK_SLAB))observe(cases,level,item,state,Blocks.AIR.defaultBlockState(),Direction.UP,.5,BlockPos.ZERO);
    }
    var fixtures=new ArrayList<BlockState>();
    for(var block:List.of(Blocks.AIR,Blocks.STONE,Blocks.WATER,Blocks.LAVA,Blocks.SHORT_GRASS,Blocks.SNOW))fixtures.addAll(block.getStateDefinition().getPossibleStates());
    for(var item:slabItems)fixtures.addAll(((BlockItem)item).getBlock().getStateDefinition().getPossibleStates());
    // Every slab's six states, all faces, the exact half boundary and adjacent float32 values.
    for(var item:slabItems)for(var clicked:((BlockItem)item).getBlock().getStateDefinition().getPossibleStates())for(var face:Direction.values())for(double y:new double[]{.25,Math.nextDown(.5f),.5,Math.nextUp(.5f),.75}){
      observe(cases,level,item,clicked,Blocks.AIR.defaultBlockState(),face,y,new BlockPos(-29999984,-64,29999984));
      observe(cases,level,item,Blocks.STONE.defaultBlockState(),clicked,face,y,new BlockPos(29999984,319,-29999984));
    }
    // Every admitted held block against solid, replaceable, liquid and different slab states.
    var allItems=new ArrayList<Item>(slabItems);for(var id:plain.keySet())allItems.add(BuiltInRegistries.ITEM.byId(Integer.parseInt(id)));
    for(var item:allItems)for(var state:fixtures)for(var face:List.of(Direction.UP,Direction.DOWN,Direction.NORTH)){
      observe(cases,level,item,state,Blocks.AIR.defaultBlockState(),face,.5,BlockPos.ZERO);
      observe(cases,level,item,Blocks.STONE.defaultBlockState(),state,face,.5,BlockPos.ZERO);
    }
    var packets=new JsonArray();
    for(var hand:InteractionHand.values())for(var face:Direction.values())for(var pos:List.of(BlockPos.ZERO,new BlockPos(-33554432,-2048,33554431),new BlockPos(33554431,2047,-33554432)))for(int sequence:new int[]{0,127,128,Integer.MAX_VALUE})for(boolean inside:new boolean[]{false,true})for(boolean border:new boolean[]{false,true}){
      var hit=new BlockHitResult(new Vec3(pos.getX()+.25,pos.getY()+.5,pos.getZ()+.75),face,pos,inside,border);
      var packet=new ServerboundUseItemOnPacket(hand,hit,sequence);var buffer=new FriendlyByteBuf(Unpooled.buffer());
      try{ServerboundUseItemOnPacket.STREAM_CODEC.encode(buffer,packet);var raw=new byte[buffer.readableBytes()];buffer.getBytes(buffer.readerIndex(),raw);var decoded=ServerboundUseItemOnPacket.STREAM_CODEC.decode(buffer);
        var decodedHit=decoded.hitResult();
        if(buffer.isReadable()||decoded.hand()!=hand||decoded.sequence()!=sequence||!decodedHit.getBlockPos().equals(pos)||decodedHit.getDirection()!=face||!decodedHit.getLocation().equals(hit.getLocation())||decodedHit.isInside()!=inside||decodedHit.isWorldBorderHit()!=border)throw new AssertionError("Placement codec differs");
        var row=new JsonObject();row.addProperty("hand",hand==InteractionHand.MAIN_HAND?"main":"off");row.add("position",position(pos));row.addProperty("face",face.get3DDataValue());row.addProperty("sequence",sequence);row.addProperty("inside",inside);row.addProperty("border",border);row.add("cursor",new Gson().toJsonTree(List.of(.25,.5,.75)));row.addProperty("wire",HexFormat.of().formatHex(raw));packets.add(row);
      }finally{buffer.release();}
    }
    var nonfinite=new JsonArray();
    for(int axis=0;axis<3;axis++)for(int bits:new int[]{0x7fc00000,0x7f800000,0xff800000}){
      var buffer=new FriendlyByteBuf(Unpooled.buffer());
      try{buffer.writeVarInt(0);buffer.writeBlockPos(BlockPos.ZERO);buffer.writeVarInt(Direction.UP.get3DDataValue());for(int i=0;i<3;i++)buffer.writeInt(i==axis?bits:Float.floatToIntBits(.5f));buffer.writeBoolean(false);buffer.writeBoolean(false);buffer.writeVarInt(1);
        var raw=new byte[buffer.readableBytes()];buffer.getBytes(buffer.readerIndex(),raw);var decoded=ServerboundUseItemOnPacket.STREAM_CODEC.decode(buffer);var location=decoded.hitResult().getLocation();double value=axis==0?location.x:axis==1?location.y:location.z;
        if(buffer.isReadable()||decoded.sequence()!=1||Double.isFinite(value))throw new AssertionError("Native codec must retain nonfinite hit for gameplay admission");
        var row=new JsonObject();row.addProperty("wire",HexFormat.of().formatHex(raw));nonfinite.add(row);
      }finally{buffer.release();}
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.addProperty("state_count",flags.size());facts.addProperty("replaceability",HexFormat.of().formatHex(flags.toByteArray()));facts.add("plain",plain);facts.add("slabs",slabs);
    var observed=new JsonObject();observed.add("contexts",cases);observed.add("packets",packets);observed.add("nonfinite",nonfinite);observed.add("unsupported_replacement",new Gson().toJsonTree(unsupported));
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");Files.writeString(Path.of(args[1]),new Gson().toJson(observed));
    System.out.println("PASS: "+cases.size()+" actual placement contexts, "+packets.size()+" native use-on packets and "+nonfinite.size()+" acknowledgeable nonfinite hits, 101 slab families; specialized replacement excluded: "+unsupported);
  }
}
