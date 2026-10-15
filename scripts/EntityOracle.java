import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.*;
import net.minecraft.network.syncher.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.*;
import net.minecraft.world.item.component.CustomData;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.world.phys.Vec3;
import net.minecraft.network.LpVec3;

/** Original independent fixtures using actual Mojang encoders/decoders, without gameplay. */
public class EntityOracle {
  private static RegistryAccess.Frozen registries;
  private static EntityType<?> itemType;
  private static final int ID = 300, COLLECTOR = 301;
  private static final UUID UUID_VALUE = UUID.fromString("00010203-0405-0607-0809-0a0b0c0d0e0f");
  private static final HexFormat HEX = HexFormat.of();

  private static EntityDataAccessor<?> accessor(Class<?> owner, String name) throws Exception {
    var field = owner.getDeclaredField(name); field.setAccessible(true);
    return (EntityDataAccessor<?>)field.get(null);
  }
  private static List<Double> vector(Vec3 v) { return List.of(v.x, v.y, v.z); }
  private static Vec3 vector(JsonArray values) {
    return new Vec3(values.get(0).getAsDouble(), values.get(1).getAsDouble(), values.get(2).getAsDouble());
  }
  private static String hex(RegistryFriendlyByteBuf buf) {
    byte[] bytes = new byte[buf.readableBytes()]; buf.readBytes(bytes); return HEX.formatHex(bytes);
  }
  private static String velocity(Vec3 v) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.buffer(), registries);
    try { Vec3.LP_STREAM_CODEC.encode(buf, v); return hex(buf); } finally { buf.release(); }
  }
  private static Vec3 decodeVelocity(String hex) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HEX.parseHex(hex)), registries);
    try { var v = Vec3.LP_STREAM_CODEC.decode(buf); if(buf.isReadable()) throw new AssertionError("Trailing velocity bytes"); return v; }
    finally { buf.release(); }
  }
  private static Map<String,Vec3> velocities() {
    var cases = new LinkedHashMap<String,Vec3>();
    cases.put("zero", Vec3.ZERO); cases.put("tiny", new Vec3(1e-6,-1e-6,1e-6));
    cases.put("threshold_below", new Vec3(Math.nextDown(LpVec3.ABS_MIN_VALUE),0,0));
    cases.put("threshold", new Vec3(LpVec3.ABS_MIN_VALUE,0,0));
    cases.put("threshold_above", new Vec3(Math.nextUp(LpVec3.ABS_MIN_VALUE),0,0));
    cases.put("typical", new Vec3(0.1,0.2,-0.3));
    cases.put("one_below", new Vec3(Math.nextDown(1.0),0,0));
    cases.put("one", new Vec3(1.0,0,0)); cases.put("one_above", new Vec3(Math.nextUp(1.0),0,0));
    cases.put("three", new Vec3(3.0,-2.0,1.0));
    cases.put("three_above", new Vec3(Math.nextUp(3.0),0,0));
    cases.put("scale_four", new Vec3(-4.0,2.5,-1.75));
    cases.put("scale_five", new Vec3(5.0,-2.1,0.001));
    cases.put("unsigned_scale", new Vec3(8_589_934_592.0,-17,0));
    cases.put("maximum", new Vec3(LpVec3.ABS_MAX_VALUE,-LpVec3.ABS_MAX_VALUE,0));
    cases.put("clamped", new Vec3(1e100,-1e100,0));
    var random = new Random(2603);
    for (int i = 0; i < 256; i++) {
      double scale = Math.scalb(1.0, random.nextInt(48) - 14);
      cases.put("random_"+i, new Vec3((random.nextDouble()*2-1)*scale,(random.nextDouble()*2-1)*scale,(random.nextDouble()*2-1)*scale));
    }
    return cases;
  }

  @SuppressWarnings({"rawtypes","unchecked"})
  private static SynchedEntityData.DataValue<?> value(EntityDataAccessor<?> accessor, Object value) {
    return new SynchedEntityData.DataValue(accessor.id(), accessor.serializer(), value);
  }

  private static Map<String,Object> packets() throws Exception {
    var cases = new LinkedHashMap<String,Object>();
    var vectors = velocities();
    for (var name : List.of("zero","typical","scale_four","unsigned_scale","maximum","clamped")) {
      Vec3 v = vectors.get(name);
      cases.put("spawn_"+name, new ClientboundAddEntityPacket(ID,UUID_VALUE,-3.25,64.2,1.75,22.5f,-91.0f,itemType,0,v,-91.0));
      cases.put("motion_"+name, new ClientboundSetEntityMotionPacket(ID,v));
    }
    for (double yaw : new double[]{-360.0,-1.40624999,1.40624999,1.40625,359.99999,999999.9})
      cases.put("angle_"+Double.toString(yaw), new ClientboundAddEntityPacket(ID,UUID_VALUE,0,64,0,0,(float)yaw,itemType,0,Vec3.ZERO,yaw));
    var stone = new ItemStack(Items.STONE,7);
    stone.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
    var custom = new CompoundTag(); custom.putString("probe","entity \u0000😀é");
    stone.set(DataComponents.CUSTOM_DATA,CustomData.of(custom));
    stone.remove(DataComponents.RARITY);
    var item = accessor(ItemEntity.class,"DATA_ITEM");
    var flags = accessor(Entity.class,"DATA_SHARED_FLAGS_ID");
    var gravity = accessor(Entity.class,"DATA_NO_GRAVITY");
    cases.put("metadata",new ClientboundSetEntityDataPacket(ID,List.of(value(flags,(byte)64),value(gravity,true),value(item,stone))));
    cases.put("metadata_empty_stack",new ClientboundSetEntityDataPacket(ID,List.of(value(item,ItemStack.EMPTY))));
    cases.put("metadata_empty",new ClientboundSetEntityDataPacket(ID,List.of()));
    cases.put("metadata_clear_flags",new ClientboundSetEntityDataPacket(ID,List.of(value(flags,(byte)0),value(gravity,false))));
    var pose = accessor(Entity.class,"DATA_POSE");
    var frozen = accessor(Entity.class,"DATA_TICKS_FROZEN");
    var air = accessor(Entity.class,"DATA_AIR_SUPPLY_ID");
    for(int supply:new int[]{-20,-19,-1,0,1,127,128,299,300})
      cases.put("air_"+supply,new ClientboundSetEntityDataPacket(ID,List.of(value(air,supply))));
    var health = accessor(LivingEntity.class,"DATA_HEALTH_ID");
    for(float points:new float[]{0,Float.MIN_VALUE,.1f,7.25f,20,1024}){
      cases.put("health_"+Float.toString(points),new ClientboundSetHealthPacket(points,20,5));
      cases.put("health_metadata_"+Float.toString(points),new ClientboundSetEntityDataPacket(ID,List.of(value(health,points))));
    }
    for(int ticks:new int[]{0,1,2,127,128,139,140})
      cases.put("frozen_"+ticks,new ClientboundSetEntityDataPacket(ID,List.of(value(frozen,ticks))));
    for (var selected : Pose.values())
      cases.put("pose_"+selected.getSerializedName(),new ClientboundSetEntityDataPacket(ID,List.of(value(pose,selected))));
    cases.put("pickup",new ClientboundTakeItemEntityPacket(ID,COLLECTOR,7));
    cases.put("remove",new ClientboundRemoveEntitiesPacket(ID,COLLECTOR));
    cases.put("remove_empty",new ClientboundRemoveEntitiesPacket());
    return cases;
  }

  @SuppressWarnings({"rawtypes","unchecked"})
  private static String packet(Object packet) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
    try {
      var protocol = GameProtocols.CLIENTBOUND_TEMPLATE.bind(b -> new RegistryFriendlyByteBuf(b,registries));
      protocol.codec().encode(buf,(net.minecraft.network.protocol.Packet)packet);
      return hex(buf);
    } finally { buf.release(); }
  }
  private static void decodePacket(String encoded, Object expected) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HEX.parseHex(encoded)),registries);
    try {
      var protocol = GameProtocols.CLIENTBOUND_TEMPLATE.bind(b -> new RegistryFriendlyByteBuf(b,registries));
      var decoded = protocol.codec().decode(buf);
      if (buf.isReadable()) throw new AssertionError("Trailing entity packet bytes");
      if (expected instanceof ClientboundSetEntityDataPacket metadata) {
        if (!(decoded instanceof ClientboundSetEntityDataPacket actual) || actual.id()!=metadata.id() || actual.packedItems().size()!=metadata.packedItems().size())
          throw new AssertionError("Wrong metadata packet");
        for (int i=0; i<metadata.packedItems().size(); i++) {
          var a=actual.packedItems().get(i); var e=metadata.packedItems().get(i);
          if (a.id()!=e.id() || a.serializer()!=e.serializer()) throw new AssertionError("Wrong metadata accessor");
          if (e.value() instanceof ItemStack stack) {
            var actualStack=(ItemStack)a.value();
            if (!ItemStack.matches(actualStack,stack) || !actualStack.getComponentsPatch().equals(stack.getComponentsPatch()))
              throw new AssertionError("Metadata stack or patch differs");
          } else if (!Objects.equals(a.value(),e.value())) throw new AssertionError("Wrong metadata value");
        }
      } else if (!packet(decoded).equals(packet(expected))) throw new AssertionError("Elixir packet differs from vanilla");
    } finally { buf.release(); }
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    registries = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    itemType = BuiltInRegistries.ENTITY_TYPE.getOrThrow(ResourceKey.create(Registries.ENTITY_TYPE,Identifier.parse("minecraft:item"))).value();
    if (args[0].equals("generate")) {
      var vectors = new ArrayList<Map<String,Object>>();
      velocities().forEach((name,v) -> vectors.add(Map.of("name",name,"source",vector(v),"wire",velocity(v),"decoded",vector(decodeVelocity(velocity(v))))));
      var messages = new ArrayList<Map<String,Object>>();
      packets().forEach((name,p) -> messages.add(Map.of("name",name,"wire",packet(p))));
      Files.writeString(Path.of(args[1]),new Gson().toJson(Map.of("velocities",vectors,"packets",messages)));
    } else {
      var fixtures = JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonObject();
      var expectedVelocities = velocities(); var expectedPackets = packets();
      var vectors = fixtures.getAsJsonArray("velocities"); var messages = fixtures.getAsJsonArray("packets");
      if (vectors.size()!=expectedVelocities.size() || messages.size()!=expectedPackets.size()) throw new AssertionError("Missing entity fixtures");
      for (var entry : vectors) {
        var v=entry.getAsJsonObject(); var name=v.get("name").getAsString();
        String expected=velocity(expectedVelocities.get(name)), actual=v.get("wire").getAsString();
        if (!expected.equals(actual) || !decodeVelocity(actual).equals(vector(v.getAsJsonArray("decoded")))) throw new AssertionError("Velocity differs: "+name);
      }
      for (var entry : messages) {
        var p=entry.getAsJsonObject(); var name=p.get("name").getAsString();
        String expected=packet(expectedPackets.get(name)), actual=p.get("wire").getAsString();
        // Component patch entry ordering is not canonical; compare typed values
        // and exact patch contents after Mojang decoding for metadata packets.
        if (!(expectedPackets.get(name) instanceof ClientboundSetEntityDataPacket) && !expected.equals(actual))
          throw new AssertionError("Packet bytes differ: "+name);
        decodePacket(actual,expectedPackets.get(name));
      }
      System.out.println("PASS: Mojang 26.3 verified "+vectors.size()+" packed velocities and "+messages.size()+" complete item entity packets, including metadata, float32 angles, motion, pickup and removal.");
    }
  }
}
