import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.component.DataComponents;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.world.item.*;
import net.minecraft.world.item.component.TooltipDisplay;

/** Original independent fixtures for vanilla tooltip flags, sets, shows and equality. */
public class TooltipOracle {
  private static RegistryAccess.Frozen registries;
  private static final List<String> names=new ArrayList<>();
  private static final List<Map<String,Object>> fixtures=new ArrayList<>();
  private static final List<TooltipDisplay> decoded=new ArrayList<>();
  private static RegistryFriendlyByteBuf buffer(byte[] bytes) {
    return new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(bytes),registries);
  }
  private static byte[] raw(int hide,int count,int... ids) {
    var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
    try {
      buf.writeByte(hide);buf.writeVarInt(count);for(int id:ids)buf.writeVarInt(id);
      byte[] bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);return bytes;
    }finally{buf.release();}
  }
  private static void probe(String name,byte[] raw,boolean bounded) {
    var row=new LinkedHashMap<String,Object>();row.put("name",name);
    row.put("input",HexFormat.of().formatHex(raw));row.put("bounded",bounded);
    var buf=buffer(raw);
    try {
      var value=TooltipDisplay.STREAM_CODEC.decode(buf);
      if(buf.isReadable())throw new IllegalArgumentException("Trailing fixture bytes");
      var hidden=value.hiddenComponents().stream().map(t->BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(t).toString()).sorted().toList();
      row.put("accepted",true);row.put("hide",value.hideTooltip());row.put("hidden",hidden);
      var shows=new ArrayList<Boolean>();
      for(var type:BuiltInRegistries.DATA_COMPONENT_TYPE)shows.add(value.shows(type));
      row.put("shows",shows);decoded.add(value);
    }catch(Exception error){row.put("accepted",false);decoded.add(null);}
    finally{buf.release();}
    fixtures.add(row);
  }
  private static void generate() {
    for(int flag:List.of(0,1,2,127,128,255))probe("empty/"+flag,raw(flag,0),true);
    for(int id=0;id<names.size();id++)for(int flag:List.of(0,1))
      probe(names.get(id)+"/"+flag,raw(flag,1,id),true);
    probe("ordered",raw(0,3,0,10,40),true);
    probe("reversed",raw(0,3,40,10,0),true);
    probe("duplicates",raw(0,5,40,10,0,40,10),true);
    probe("hidden-still-matters",raw(1,3,0,10,40),true);
    int[] all=new int[names.size()];for(int i=0;i<all.length;i++)all[i]=i;
    probe("all-components",raw(0,all.length,all),true);
    for(int count:List.of(1024,1025)){int[] ids=new int[count];Arrays.fill(ids,40);probe("raw-count/"+count,raw(0,count,ids),count<=1024);}
    probe("unknown",raw(0,1,names.size()),true);
    probe("unknown-after-known",raw(0,2,40,names.size()),true);
    probe("negative-id",raw(0,1,-1),true);
    probe("negative-count",raw(0,-1),true);
    probe("truncated",raw(0,1),true);
    probe("empty-bytes",new byte[0],true);
    probe("trailing",raw(0,0,0),true);
  }
  private static void verify(String path) throws Exception {
    var rows=JsonParser.parseString(Files.readString(Path.of(path))).getAsJsonArray();
    for(var row:rows){
      var object=row.getAsJsonObject();var expected=decoded.get(object.get("index").getAsInt());
      var buf=buffer(HexFormat.of().parseHex(object.get("value").getAsString()));
      try{if(!expected.equals(TooltipDisplay.STREAM_CODEC.decode(buf))||buf.isReadable())throw new AssertionError("Elixir tooltip value differs: "+object.get("index"));}finally{buf.release();}
      var stack=new ItemStack(Items.STONE,2);stack.set(DataComponents.TOOLTIP_DISPLAY,expected);
      for(var key:List.of("stack","untrusted")){
        buf=buffer(HexFormat.of().parseHex(object.get(key).getAsString()));
        try{
          var actual=(key.equals("stack")?ItemStack.OPTIONAL_STREAM_CODEC:ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC).decode(buf);
          if(!ItemStack.matches(stack,actual)||buf.isReadable())throw new AssertionError("Elixir tooltip stack differs: "+object.get("index")+"/"+key);
        }finally{buf.release();}
      }
    }
    System.out.println("PASS: Mojang decoded "+rows.size()+" Elixir tooltip controls and both stack formats.");
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    registries=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    for(var type:BuiltInRegistries.DATA_COMPONENT_TYPE)names.add(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(type).toString());
    generate();
    if(args[0].equals("verify")){verify(args[1]);return;}
    var pairs=new ArrayList<List<Integer>>();
    for(int i=0;i<decoded.size();i++)for(int j=i;j<decoded.size();j++)
      if(decoded.get(i)!=null&&decoded.get(j)!=null&&(boolean)fixtures.get(i).get("bounded")&&(boolean)fixtures.get(j).get("bounded"))
        pairs.add(List.of(i,j,decoded.get(i).equals(decoded.get(j))?1:0));
    Files.writeString(Path.of(args[0]),new Gson().toJson(Map.of("registry",names,"fixtures",fixtures,"equality",pairs)));
    System.out.println("PASS: Generated "+fixtures.size()+" native tooltip cases and "+pairs.size()+" equality pairs across "+names.size()+" component IDs.");
  }
}
