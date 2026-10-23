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
import net.minecraft.world.entity.item.PrimedTnt;
import net.minecraft.world.entity.monster.zombie.Zombie;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.effect.MobEffects;
import net.minecraft.world.item.*;
import net.minecraft.world.item.component.CustomData;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.world.phys.Vec3;
import net.minecraft.network.LpVec3;

/**
 * Original independent fixtures using actual Mojang encoders/decoders, without gameplay, and
 * (`facts`) every entity type's facts as one generated table (VMC-043a).
 */
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
    var absorption = accessor(Player.class,"DATA_PLAYER_ABSORPTION_ID");
    for(float points:new float[]{0,Float.MIN_VALUE,.1f,4,1024,2048}){
      cases.put("absorption_"+Float.toString(points),new ClientboundSetEntityDataPacket(ID,List.of(value(absorption,points))));
      cases.put("health_absorption_"+Float.toString(points),new ClientboundSetEntityDataPacket(ID,List.of(value(health,18f),value(absorption,points))));
    }
    for(int amp=-1;amp<=255;amp++){
      var attributes=new AttributeMap(Player.createAttributes().build());
      if(amp>=0)MobEffects.ABSORPTION.value().addAttributeModifiers(attributes,amp);
      cases.put("absorption_maximum_"+amp,new ClientboundUpdateAttributesPacket(ID,List.of(attributes.getInstance(Attributes.MAX_ABSORPTION))));
      if(amp>=0)MobEffects.JUMP_BOOST.value().addAttributeModifiers(attributes,amp);
      cases.put("jump_safe_distance_"+amp,new ClientboundUpdateAttributesPacket(ID,List.of(attributes.getInstance(Attributes.SAFE_FALL_DISTANCE))));
    }
    for(float points:new float[]{0,Float.MIN_VALUE,.1f,7.25f,20,1024}){
      cases.put("health_"+Float.toString(points),new ClientboundSetHealthPacket(points,20,5));
      cases.put("health_metadata_"+Float.toString(points),new ClientboundSetEntityDataPacket(ID,List.of(value(health,points))));
    }
    for(int ticks:new int[]{0,1,2,127,128,139,140})
      cases.put("frozen_"+ticks,new ClientboundSetEntityDataPacket(ID,List.of(value(frozen,ticks))));
    for (var selected : Pose.values())
      cases.put("pose_"+selected.getSerializedName(),new ClientboundSetEntityDataPacket(ID,List.of(value(pose,selected))));
    // Bodies (VMC-043a): spawns facing their yaw and head, mob and primed TNT data, a zombie's attributes.
    for (var type : List.of("zombie","tnt")) {
      var entityType = BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:"+type));
      cases.put("body_spawn_"+type,new ClientboundAddEntityPacket(ID,UUID_VALUE,-3.25,64.2,1.75,22.5f,-91.0f,entityType,0,Vec3.ZERO,45.0));
    }
    cases.put("body_metadata_mob",new ClientboundSetEntityDataPacket(ID,List.of(value(pose,Pose.DYING),value(health,20f),value(accessor(Mob.class,"DATA_MOB_FLAGS_ID"),(byte)2))));
    var unstable = net.minecraft.world.level.block.Blocks.TNT.defaultBlockState().setValue(net.minecraft.world.level.block.state.properties.BlockStateProperties.UNSTABLE,true);
    cases.put("body_metadata_tnt",new ClientboundSetEntityDataPacket(ID,List.of(value(accessor(PrimedTnt.class,"DATA_FUSE_ID"),79),value(accessor(PrimedTnt.class,"DATA_BLOCK_STATE_ID"),unstable))));
    var zombie=new AttributeMap(DefaultAttributes.getSupplier(EntityTypes.ZOMBIE));
    var synced=new ArrayList<AttributeInstance>();
    BuiltInRegistries.ATTRIBUTE.listElements().forEach(h -> {
      if (DefaultAttributes.getSupplier(EntityTypes.ZOMBIE).hasAttribute(h) && h.value().isClientSyncable()) synced.add(zombie.getInstance(h));
    });
    cases.put("body_attributes_zombie",new ClientboundUpdateAttributesPacket(ID,synced));
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

  // ---- facts (VMC-043a): one table of every entity type ----

  private static Map<String,Integer> field(Class<?> owner, String name) throws Exception {
    var accessor = accessor(owner, name);
    var facts = new TreeMap<String,Integer>();
    facts.put("index", accessor.id());
    facts.put("serializer", EntityDataSerializers.getSerializedId(accessor.serializer()));
    return facts;
  }

  private static String placementName(SpawnPlacementType placement) throws Exception {
    for (var f : SpawnPlacementTypes.class.getFields())
      if (f.get(null) == placement) return f.getName().toLowerCase(Locale.ROOT);
    throw new AssertionError("Unknown spawn placement type");
  }

  @SuppressWarnings("unchecked")
  private static Map<String,Object> facts() throws Exception {
    var dataField = SpawnPlacements.class.getDeclaredField("DATA_BY_TYPE"); dataField.setAccessible(true);
    var placements = (Map<EntityType<?>,?>)dataField.get(null);
    var types = new TreeMap<String,Object>();
    for (var type : BuiltInRegistries.ENTITY_TYPE) {
      var name = BuiltInRegistries.ENTITY_TYPE.getKey(type).toString();
      var dimensions = type.getDimensions();
      var t = new TreeMap<String,Object>();
      t.put("id", BuiltInRegistries.ENTITY_TYPE.getId(type));
      t.put("category", type.getCategory().getName());
      t.put("width", dimensions.width()); t.put("height", dimensions.height());
      t.put("eye_height", dimensions.eyeHeight()); t.put("fixed", dimensions.fixed());
      t.put("fire_immune", type.fireImmune()); t.put("summonable", type.canSummon());
      t.put("saved", type.canSerialize()); t.put("peaceful", type.isAllowedInPeaceful());
      t.put("spawn_far", type.canSpawnFarFromPlayer());
      t.put("tracking_range", type.clientTrackingRange());
      t.put("update_interval", type.updateInterval()); t.put("track_deltas", type.trackDeltas());
      t.put("description", type.getDescriptionId());
      t.put("loot_table", type.getDefaultLootTable().map(k -> k.identifier().toString()).orElse(null));
      if (placements.containsKey(type)) {
        t.put("spawn_placement", placementName(SpawnPlacements.getPlacementType(type)));
        t.put("spawn_heightmap", SpawnPlacements.getHeightmapType(type).getSerializedName());
      }
      if (DefaultAttributes.hasSupplier(type)) {
        @SuppressWarnings("rawtypes") var supplier = DefaultAttributes.getSupplier((EntityType)type);
        var attributes = new TreeMap<String,Double>();
        BuiltInRegistries.ATTRIBUTE.listElements().forEach(holder -> {
          if (supplier.hasAttribute(holder)) attributes.put(holder.key().identifier().toString(), supplier.getBaseValue(holder));
        });
        t.put("attributes", attributes);
      }
      types.put(name, t);
    }
    var categories = new TreeMap<String,Object>();
    for (var category : MobCategory.values()) {
      var c = new TreeMap<String,Object>();
      c.put("max", category.getMaxInstancesPerChunk()); c.put("friendly", category.isFriendly());
      c.put("persistent", category.isPersistent()); c.put("despawn_distance", category.getDespawnDistance());
      c.put("no_despawn_distance", category.getNoDespawnDistance());
      categories.put(category.getName(), c);
    }
    var serializers = new TreeMap<String,Integer>();
    for (var f : EntityDataSerializers.class.getFields())
      if (java.lang.reflect.Modifier.isStatic(f.getModifiers()) && EntityDataSerializer.class.isAssignableFrom(f.getType()))
        serializers.put(f.getName().toLowerCase(Locale.ROOT), EntityDataSerializers.getSerializedId((EntityDataSerializer<?>)f.get(null)));
    var fields = new TreeMap<String,Object>();
    fields.put("shared_flags", field(Entity.class, "DATA_SHARED_FLAGS_ID"));
    fields.put("air_supply", field(Entity.class, "DATA_AIR_SUPPLY_ID"));
    fields.put("custom_name", field(Entity.class, "DATA_CUSTOM_NAME"));
    fields.put("custom_name_visible", field(Entity.class, "DATA_CUSTOM_NAME_VISIBLE"));
    fields.put("silent", field(Entity.class, "DATA_SILENT"));
    fields.put("no_gravity", field(Entity.class, "DATA_NO_GRAVITY"));
    fields.put("pose", field(Entity.class, "DATA_POSE"));
    fields.put("frozen_ticks", field(Entity.class, "DATA_TICKS_FROZEN"));
    fields.put("item_stack", field(ItemEntity.class, "DATA_ITEM"));
    fields.put("experience_value", field(ExperienceOrb.class, "DATA_VALUE"));
    fields.put("living_flags", field(LivingEntity.class, "DATA_LIVING_ENTITY_FLAGS"));
    fields.put("health", field(LivingEntity.class, "DATA_HEALTH_ID"));
    fields.put("effect_particles", field(LivingEntity.class, "DATA_EFFECT_PARTICLES"));
    fields.put("effect_ambience", field(LivingEntity.class, "DATA_EFFECT_AMBIENCE_ID"));
    fields.put("arrow_count", field(LivingEntity.class, "DATA_ARROW_COUNT_ID"));
    fields.put("stinger_count", field(LivingEntity.class, "DATA_STINGER_COUNT_ID"));
    fields.put("sleeping_pos", field(LivingEntity.class, "SLEEPING_POS_ID"));
    fields.put("absorption", field(Player.class, "DATA_PLAYER_ABSORPTION_ID"));
    fields.put("mob_flags", field(Mob.class, "DATA_MOB_FLAGS_ID"));
    fields.put("zombie_baby", field(Zombie.class, "DATA_BABY_ID"));
    fields.put("zombie_special_type", field(Zombie.class, "DATA_SPECIAL_TYPE_ID"));
    fields.put("zombie_drowned_conversion", field(Zombie.class, "DATA_DROWNED_CONVERSION_ID"));
    // VMC-043b: the overworld hostiles.
    fields.put("zombie_villager_converting", field(net.minecraft.world.entity.monster.zombie.ZombieVillager.class, "DATA_CONVERTING_ID"));
    fields.put("zombie_villager_data", field(net.minecraft.world.entity.monster.zombie.ZombieVillager.class, "DATA_VILLAGER_DATA"));
    fields.put("zombie_villager_finalized", field(net.minecraft.world.entity.monster.zombie.ZombieVillager.class, "DATA_VILLAGER_DATA_FINALIZED"));
    fields.put("skeleton_stray_conversion", field(net.minecraft.world.entity.monster.skeleton.Skeleton.class, "DATA_STRAY_CONVERSION_ID"));
    fields.put("bogged_sheared", field(net.minecraft.world.entity.monster.skeleton.Bogged.class, "DATA_SHEARED"));
    fields.put("creeper_swell_dir", field(net.minecraft.world.entity.monster.Creeper.class, "DATA_SWELL_DIR"));
    fields.put("creeper_powered", field(net.minecraft.world.entity.monster.Creeper.class, "DATA_IS_POWERED"));
    fields.put("creeper_ignited", field(net.minecraft.world.entity.monster.Creeper.class, "DATA_IS_IGNITED"));
    fields.put("spider_flags", field(net.minecraft.world.entity.monster.spider.Spider.class, "DATA_FLAGS_ID"));
    fields.put("enderman_carry_state", field(net.minecraft.world.entity.monster.Enderman.class, "DATA_CARRY_STATE"));
    fields.put("enderman_creepy", field(net.minecraft.world.entity.monster.Enderman.class, "DATA_CREEPY"));
    fields.put("enderman_stared_at", field(net.minecraft.world.entity.monster.Enderman.class, "DATA_STARED_AT"));
    fields.put("raider_celebrating", field(net.minecraft.world.entity.raid.Raider.class, "IS_CELEBRATING"));
    fields.put("witch_using_item", field(net.minecraft.world.entity.monster.Witch.class, "DATA_USING_ITEM"));
    fields.put("cube_size", field(net.minecraft.world.entity.monster.cubemob.AbstractCubeMob.class, "ID_SIZE"));
    fields.put("phantom_size", field(net.minecraft.world.entity.monster.Phantom.class, "ID_SIZE"));
    fields.put("tnt_fuse", field(PrimedTnt.class, "DATA_FUSE_ID"));
    fields.put("tnt_block_state", field(PrimedTnt.class, "DATA_BLOCK_STATE_ID"));
    fields.put("falling_block_start_pos", field(net.minecraft.world.entity.item.FallingBlockEntity.class, "DATA_START_POS"));
    // VMC-037o: arrows, thrown items, fireballs and eyes of ender, the dragon's breath cloud.
    fields.put("arrow_flags", field(net.minecraft.world.entity.projectile.arrow.AbstractArrow.class, "ID_FLAGS"));
    fields.put("arrow_pierce_level", field(net.minecraft.world.entity.projectile.arrow.AbstractArrow.class, "PIERCE_LEVEL"));
    fields.put("arrow_in_ground", field(net.minecraft.world.entity.projectile.arrow.AbstractArrow.class, "IN_GROUND"));
    fields.put("arrow_color", field(net.minecraft.world.entity.projectile.arrow.Arrow.class, "ID_EFFECT_COLOR"));
    fields.put("thrown_item", field(net.minecraft.world.entity.projectile.throwableitemprojectile.ThrowableItemProjectile.class, "DATA_ITEM_STACK"));
    fields.put("fireball_item", field(net.minecraft.world.entity.projectile.hurtingprojectile.Fireball.class, "DATA_ITEM_STACK"));
    fields.put("eye_item", field(net.minecraft.world.entity.projectile.EyeOfEnder.class, "DATA_ITEM_STACK"));
    fields.put("cloud_radius", field(net.minecraft.world.entity.AreaEffectCloud.class, "DATA_RADIUS"));
    fields.put("cloud_waiting", field(net.minecraft.world.entity.AreaEffectCloud.class, "DATA_WAITING"));
    fields.put("ageable_baby", field(net.minecraft.world.entity.AgeableMob.class, "DATA_BABY_ID"));
    fields.put("cloud_particle", field(net.minecraft.world.entity.AreaEffectCloud.class, "DATA_PARTICLE"));
    // VMC-043d: the Nether's mobs.
    fields.put("blaze_flags", field(net.minecraft.world.entity.monster.Blaze.class, "DATA_FLAGS_ID"));
    fields.put("ghast_charging", field(net.minecraft.world.entity.monster.Ghast.class, "DATA_IS_CHARGING"));
    fields.put("piglin_immune", field(net.minecraft.world.entity.monster.piglin.AbstractPiglin.class, "DATA_IMMUNE_TO_ZOMBIFICATION"));
    fields.put("piglin_baby", field(net.minecraft.world.entity.monster.piglin.Piglin.class, "DATA_BABY_ID"));
    fields.put("piglin_charging_crossbow", field(net.minecraft.world.entity.monster.piglin.Piglin.class, "DATA_IS_CHARGING_CROSSBOW"));
    fields.put("piglin_dancing", field(net.minecraft.world.entity.monster.piglin.Piglin.class, "DATA_IS_DANCING"));
    fields.put("hoglin_immune", field(net.minecraft.world.entity.monster.hoglin.Hoglin.class, "DATA_IMMUNE_TO_ZOMBIFICATION"));
    fields.put("strider_boost_time", field(net.minecraft.world.entity.monster.Strider.class, "DATA_BOOST_TIME"));
    fields.put("strider_suffocating", field(net.minecraft.world.entity.monster.Strider.class, "DATA_SUFFOCATING"));
    // VMC-043e: water, ambient and End mobs.
    fields.put("shulker_attach_face", field(net.minecraft.world.entity.monster.Shulker.class, "DATA_ATTACH_FACE_ID"));
    fields.put("shulker_peek", field(net.minecraft.world.entity.monster.Shulker.class, "DATA_PEEK_ID"));
    fields.put("shulker_color", field(net.minecraft.world.entity.monster.Shulker.class, "DATA_COLOR_ID"));
    fields.put("fish_from_bucket", field(net.minecraft.world.entity.animal.fish.AbstractFish.class, "FROM_BUCKET"));
    fields.put("puff_state", field(net.minecraft.world.entity.animal.fish.Pufferfish.class, "PUFF_STATE"));
    fields.put("tropical_fish_variant", field(net.minecraft.world.entity.animal.fish.TropicalFish.class, "DATA_ID_TYPE_VARIANT"));
    fields.put("salmon_type", field(net.minecraft.world.entity.animal.fish.Salmon.class, "DATA_TYPE"));
    fields.put("glow_squid_dark_ticks", field(net.minecraft.world.entity.animal.squid.GlowSquid.class, "DATA_DARK_TICKS_REMAINING"));
    fields.put("dolphin_got_fish", field(net.minecraft.world.entity.animal.dolphin.Dolphin.class, "GOT_FISH"));
    fields.put("dolphin_moistness", field(net.minecraft.world.entity.animal.dolphin.Dolphin.class, "MOISTNESS_LEVEL"));
    fields.put("turtle_has_egg", field(net.minecraft.world.entity.animal.turtle.Turtle.class, "HAS_EGG"));
    fields.put("turtle_laying_egg", field(net.minecraft.world.entity.animal.turtle.Turtle.class, "LAYING_EGG"));
    fields.put("axolotl_variant", field(net.minecraft.world.entity.animal.axolotl.Axolotl.class, "DATA_VARIANT"));
    fields.put("axolotl_playing_dead", field(net.minecraft.world.entity.animal.axolotl.Axolotl.class, "DATA_PLAYING_DEAD"));
    fields.put("axolotl_from_bucket", field(net.minecraft.world.entity.animal.axolotl.Axolotl.class, "FROM_BUCKET"));
    fields.put("guardian_moving", field(net.minecraft.world.entity.monster.Guardian.class, "DATA_ID_MOVING"));
    fields.put("guardian_attack_target", field(net.minecraft.world.entity.monster.Guardian.class, "DATA_ID_ATTACK_TARGET"));
    fields.put("bat_flags", field(net.minecraft.world.entity.ambient.Bat.class, "DATA_ID_FLAGS"));
    // VMC-043c: farm animals.
    fields.put("age_locked", field(net.minecraft.world.entity.AgeableMob.class, "AGE_LOCKED"));
    fields.put("cow_variant", field(net.minecraft.world.entity.animal.cow.Cow.class, "DATA_VARIANT_ID"));
    fields.put("cow_sound_variant", field(net.minecraft.world.entity.animal.cow.Cow.class, "DATA_SOUND_VARIANT_ID"));
    fields.put("mooshroom_type", field(net.minecraft.world.entity.animal.cow.MushroomCow.class, "DATA_TYPE"));
    fields.put("pig_boost_time", field(net.minecraft.world.entity.animal.pig.Pig.class, "DATA_BOOST_TIME"));
    fields.put("pig_variant", field(net.minecraft.world.entity.animal.pig.Pig.class, "DATA_VARIANT_ID"));
    fields.put("pig_sound_variant", field(net.minecraft.world.entity.animal.pig.Pig.class, "DATA_SOUND_VARIANT_ID"));
    fields.put("chicken_variant", field(net.minecraft.world.entity.animal.chicken.Chicken.class, "DATA_VARIANT_ID"));
    fields.put("chicken_sound_variant", field(net.minecraft.world.entity.animal.chicken.Chicken.class, "DATA_SOUND_VARIANT_ID"));
    fields.put("sheep_wool", field(net.minecraft.world.entity.animal.sheep.Sheep.class, "DATA_WOOL_ID"));
    fields.put("rabbit_type", field(net.minecraft.world.entity.animal.rabbit.Rabbit.class, "DATA_TYPE_ID"));
    var version = SharedConstants.getCurrentVersion();
    var out = new LinkedHashMap<String,Object>();
    out.put("version", version.id()); out.put("data_version", version.dataVersion().version());
    out.put("protocol", version.protocolVersion()); out.put("server_sha1", VersionMetadata.serverSha1());
    out.put("serializers", serializers); out.put("fields", fields);
    out.put("categories", categories); out.put("types", types);
    return out;
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    if (args[0].equals("facts")) {
      Files.writeString(Path.of(args[1]), new GsonBuilder().serializeNulls().setPrettyPrinting().create().toJson(facts()) + "\n");
      return;
    }
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
