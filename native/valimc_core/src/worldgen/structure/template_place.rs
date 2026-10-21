//! Template pieces placed into chunks (VMC-025f2): `TemplateStructurePiece`
//! (the template inside the chunk's box, then its data markers and jigsaw
//! blocks) and each family's own steps: igloos, shipwrecks, ocean ruins,
//! nether fossils, end cities and woodland mansions.

use super::super::blocks::{BlockSet, Heightmap, FLUID_WATER};
use super::super::random::Random;
use super::super::region::{entity_kind, Entity};
use super::super::template::{
    parse_state, snbt_string, transform, BoundingBox as TemplateBox, Mirror, PlaceSettings,
    Processor, Rotation, Template,
};
use super::piece::{BoundingBox, Direction, Piece, PieceKind, TemplateKind, TemplatePiece};
use super::place::Ctx;
use super::templated::template_box;
use super::{BiomeSet, StructureKind};
use std::sync::Arc;

const IGLOO_LOOT: &str = "minecraft:chests/igloo_chest";
const SHIPWRECK_LOOT: [(&str, &str); 3] = [
    ("map_chest", "minecraft:chests/shipwreck_map"),
    ("treasure_chest", "minecraft:chests/shipwreck_treasure"),
    ("supply_chest", "minecraft:chests/shipwreck_supply"),
];
const RUIN_BIG_LOOT: &str = "minecraft:chests/underwater_ruin_big";
const RUIN_SMALL_LOOT: &str = "minecraft:chests/underwater_ruin_small";
const RUIN_WARM_ARCHAEOLOGY: &str = "minecraft:archaeology/ocean_ruin_warm";
const RUIN_COLD_ARCHAEOLOGY: &str = "minecraft:archaeology/ocean_ruin_cold";
const END_CITY_LOOT: &str = "minecraft:chests/end_city_treasure";
const MANSION_LOOT: &str = "minecraft:chests/woodland_mansion";

/// A template piece's `postProcess`.
pub fn post_process(
    piece: &mut Piece,
    c: &mut Ctx,
    structure: &StructureKind,
) -> Result<(), String> {
    let PieceKind::Template(t) = &mut piece.kind else {
        return Err("not a template piece".into());
    };
    let bbox = &mut piece.bbox;
    match t.kind.clone() {
        TemplateKind::Igloo => igloo(t, bbox, c),
        TemplateKind::Shipwreck { beached, .. } => shipwreck(t, bbox, c, beached),
        TemplateKind::OceanRuin {
            integrity,
            warm,
            large,
        } => {
            let StructureKind::OceanRuin {
                frequent_drowned, ..
            } = structure
            else {
                return Err("an ocean ruin piece outside an ocean ruin".into());
            };
            ocean_ruin(t, bbox, c, integrity, warm, large, frequent_drowned)
        }
        TemplateKind::NetherFossil => nether_fossil(t, bbox, c),
        TemplateKind::EndCity { overwrite } => end_city(t, bbox, c, overwrite),
        TemplateKind::Mansion => mansion(t, bbox, c),
        TemplateKind::RuinedPortal { .. } => ruined_portal(t, bbox, c),
    }
}

/// `BlockIgnoreProcessor` of these blocks.
fn ignore(c: &Ctx, names: &[&str]) -> Result<Processor, String> {
    let table = c.placer.table;
    let blocks = names
        .iter()
        .map(|n| table.block(n))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Processor::Ignore(BlockSet::from_blocks(blocks)))
}

fn template(c: &Ctx, location: &str) -> Result<Arc<Template>, String> {
    c.placer
        .templates
        .ok_or("no structure templates")?
        .template(location)
}

/// The chunk's box as template settings take it.
fn settings_box(b: BoundingBox) -> TemplateBox {
    TemplateBox {
        min: [b.min_x, b.min_y, b.min_z],
        max: [b.max_x, b.max_y, b.max_z],
    }
}

/// What a template's data markers do: called with the marker's metadata and
/// position.
type MarkerFn<'f> = dyn FnMut(&mut Ctx, &str, [i32; 3]) -> Result<(), String> + 'f;

/// `TemplateStructurePiece.postProcess`: the piece's box from the template,
/// the template placed inside the chunk's box, then each data marker
/// (`markers`, with its metadata and position) and each jigsaw block (its
/// final state) inside that box.
fn place_template(
    c: &mut Ctx,
    bbox: &mut BoundingBox,
    location: &str,
    position: [i32; 3],
    mut settings: PlaceSettings,
    markers: &mut MarkerFn,
) -> Result<(), String> {
    let templates = c.placer.templates.ok_or("no structure templates")?;
    let template = templates.template(location)?;
    settings.bounding_box = Some(settings_box(c.chunk_box));
    *bbox = template_box(
        template.size,
        position,
        settings.rotation,
        settings.pivot,
        settings.mirror,
    );
    let d = c.placer.decoration;
    if !templates.place(
        d,
        c.region,
        &template,
        position,
        c.reference,
        &settings,
        c.random,
        2,
    )? {
        return Ok(());
    }
    let table = c.placer.table;
    for (pos, _, nbt) in templates.filter_blocks(
        table,
        &template,
        position,
        &settings,
        table.block("structure_block")?,
    ) {
        let Some(snbt) = nbt.and_then(|n| n.snbt) else {
            continue;
        };
        if snbt_string(&snbt, "mode") == Some("DATA") {
            markers(c, snbt_string(&snbt, "metadata").unwrap_or(""), pos)?;
        }
    }
    for (pos, _, nbt) in templates.filter_blocks(
        table,
        &template,
        position,
        &settings,
        table.block("jigsaw")?,
    ) {
        let Some(snbt) = nbt.and_then(|n| n.snbt) else {
            continue;
        };
        let text = snbt_string(&snbt, "final_state").unwrap_or("minecraft:air");
        let state = parse_state(table, text).unwrap_or(c.placer.air);
        c.set(pos, state, 3);
    }
    Ok(())
}

/// `RandomizableContainer.setBlockEntityLootTable`: a loot table and a seed
/// for the container at `pos`, if there is one.
fn container_loot(c: &mut Ctx, pos: [i32; 3], loot_table: &str) -> Result<(), String> {
    const CONTAINERS: [&str; 9] = [
        "minecraft:chest",
        "minecraft:trapped_chest",
        "minecraft:barrel",
        "minecraft:dispenser",
        "minecraft:dropper",
        "minecraft:hopper",
        "minecraft:shulker_box",
        "minecraft:decorated_pot",
        "minecraft:crafter",
    ];
    let random = &mut *c.random;
    if let Some(entity) = c.region.block_entity(pos)? {
        if CONTAINERS.contains(&entity.kind) {
            entity.loot_table = Some(loot_table.to_string());
            entity.loot_seed = random.next_long();
        }
    }
    Ok(())
}

fn relative(settings: &PlaceSettings, pos: [i32; 3]) -> [i32; 3] {
    transform(pos, settings.mirror, settings.rotation, settings.pivot)
}

fn add(a: [i32; 3], b: [i32; 3]) -> [i32; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn igloo(t: &mut TemplatePiece, bbox: &mut BoundingBox, c: &mut Ctx) -> Result<(), String> {
    let location = t.name.clone();
    let (pivot, offset) = match location.as_str() {
        "minecraft:igloo/top" => ([3, 5, 5], [0, 0, 0]),
        "minecraft:igloo/middle" => ([1, 3, 1], [2, -3, 4]),
        "minecraft:igloo/bottom" => ([3, 6, 7], [0, -3, -2]),
        other => return Err(format!("unknown igloo template {other}")),
    };
    let mut settings = PlaceSettings::piece(
        Mirror::None,
        t.rotation,
        pivot,
        vec![ignore(c, &["structure_block"])?],
    );
    settings.waterlogging = false;
    let entrance = add(
        t.position,
        relative(&settings, [3 - offset[0], 0, -offset[2]]),
    );
    let height = c
        .region
        .height_at(Heightmap::WorldSurfaceWg, entrance[0], entrance[2]);
    let position = [
        t.position[0],
        t.position[1] + height - 90 - 1,
        t.position[2],
    ];
    let trapdoor = add(position, relative(&settings, [3, 0, 5]));
    place_template(
        c,
        bbox,
        &location,
        position,
        settings,
        &mut |c, marker, pos| {
            if marker != "chest" {
                return Ok(());
            }
            c.set(pos, c.placer.air, 3);
            let below = [pos[0], pos[1] - 1, pos[2]];
            let random = &mut *c.random;
            if let Some(entity) = c.region.block_entity(below)? {
                if entity.kind == "minecraft:chest" {
                    entity.loot_table = Some(IGLOO_LOOT.into());
                    entity.loot_seed = random.next_long();
                }
            }
            Ok(())
        },
    )?;
    if location == "minecraft:igloo/top" {
        let below = c.region.get([trapdoor[0], trapdoor[1] - 1, trapdoor[2]]);
        if !c.placer.table.is_air(below) && !c.placer.is(below, "ladder") {
            let snow = c.state("snow_block")?;
            c.set(trapdoor, snow, 3);
        }
    }
    Ok(())
}

fn shipwreck(
    t: &mut TemplatePiece,
    bbox: &mut BoundingBox,
    c: &mut Ctx,
    beached: bool,
) -> Result<(), String> {
    let location = t.name.clone();
    let size = template(c, &location)?.size;
    let settings = PlaceSettings::piece(
        Mirror::None,
        t.rotation,
        [4, 0, 15],
        vec![ignore(c, &["structure_block", "air"])?],
    );
    if let TemplateKind::Shipwreck {
        height_adjusted, ..
    } = &mut t.kind
    {
        let too_big = size[0] > 32 || size[1] > 32;
        if !*height_adjusted && !too_big {
            let heightmap = if beached {
                Heightmap::WorldSurfaceWg
            } else {
                Heightmap::OceanFloorWg
            };
            let mut min_y = c.region.min_y() + c.region.height();
            let base = size[0] * size[2];
            let mean = if base == 0 {
                c.region.height_at(heightmap, t.position[0], t.position[2])
            } else {
                let mut sum = 0;
                for z in t.position[2]..t.position[2] + size[2] {
                    for x in t.position[0]..t.position[0] + size[0] {
                        let h = c.region.height_at(heightmap, x, z);
                        sum += h;
                        min_y = min_y.min(h);
                    }
                }
                sum / base
            };
            let y = if beached {
                min_y - size[1] / 2 - c.random.next_int_bounded(3)
            } else {
                mean
            };
            *height_adjusted = true;
            t.position[1] = y;
        }
    }
    place_template(
        c,
        bbox,
        &location,
        t.position,
        settings,
        &mut |c, marker, pos| {
            if let Some((_, loot)) = SHIPWRECK_LOOT.iter().find(|(m, _)| *m == marker) {
                container_loot(c, [pos[0], pos[1] - 1, pos[2]], loot)?;
            }
            Ok(())
        },
    )
}

fn ocean_ruin(
    t: &mut TemplatePiece,
    bbox: &mut BoundingBox,
    c: &mut Ctx,
    integrity: f32,
    warm: bool,
    large: bool,
    frequent_drowned: &BiomeSet,
) -> Result<(), String> {
    let location = t.name.clone();
    let size = template(c, &location)?.size;
    let table = c.placer.table;
    let (candidate, replacement, archaeology) = if warm {
        ("sand", "suspicious_sand", RUIN_WARM_ARCHAEOLOGY)
    } else {
        ("gravel", "suspicious_gravel", RUIN_COLD_ARCHAEOLOGY)
    };
    let suspicious = Processor::capped_rule(table, candidate, replacement, archaeology, 5)?;
    let settings = PlaceSettings::piece(
        Mirror::None,
        t.rotation,
        [0, 0, 0],
        vec![
            Processor::BlockRot {
                rottable: None,
                integrity,
            },
            ignore(c, &["structure_block", "air"])?,
            suspicious,
        ],
    );
    let height = c
        .region
        .height_at(Heightmap::OceanFloorWg, t.position[0], t.position[2]);
    let mut position = [t.position[0], height, t.position[2]];
    let corner = add(
        transform(
            [size[0] - 1, 0, size[2] - 1],
            Mirror::None,
            t.rotation,
            [0, 0, 0],
        ),
        position,
    );
    position[1] = ruin_height(c, position, corner)?;
    t.position = position;
    let sea_level = c.region.sea_level;
    place_template(
        c,
        bbox,
        &location,
        position,
        settings,
        &mut |c, marker, pos| {
            match marker {
                "chest" => {
                    let water = c.placer.table.fluid(c.region.get(pos)) == FLUID_WATER
                        || c.placer.table.fluid(c.region.get(pos))
                            == super::super::blocks::FLUID_FLOWING_WATER;
                    let chest = c.state("chest")?;
                    let state =
                        c.placer
                            .with(chest, "waterlogged", if water { "true" } else { "false" });
                    c.set(pos, state, 2);
                    let random = &mut *c.random;
                    if let Some(entity) = c.region.block_entity(pos)? {
                        if entity.kind == "minecraft:chest" {
                            entity.loot_table = Some(
                                if large {
                                    RUIN_BIG_LOOT
                                } else {
                                    RUIN_SMALL_LOOT
                                }
                                .into(),
                            );
                            entity.loot_seed = random.next_long();
                        }
                    }
                }
                "drowned" => {
                    // `finalizeSpawn` adds the zombie nautilus the drowned rides
                    // before the drowned is added.
                    let at = [pos[0] as f64 + 0.5, pos[1] as f64, pos[2] as f64 + 0.5];
                    if super::mobs::finalize_drowned(c, pos, frequent_drowned)? {
                        c.region.add_entity(Entity {
                            kind: "minecraft:zombie_nautilus",
                            pos: at,
                            yaw: 0.0,
                        });
                    }
                    c.region.add_entity(Entity {
                        kind: "minecraft:drowned",
                        pos: at,
                        yaw: 0.0,
                    });
                    let state = if pos[1] > sea_level {
                        c.placer.air
                    } else {
                        c.state("water")?
                    };
                    c.set(pos, state, 2);
                }
                _ => {}
            }
            Ok(())
        },
    )
}

/// `OceanRuinPiece.getHeight`: the floor under the ruin's base, lowered to
/// the lowest floor when the ruin would hang over a drop.
fn ruin_height(c: &mut Ctx, pos: [i32; 3], corner: [i32; 3]) -> Result<i32, String> {
    let table = c.placer.table;
    let ice = table.tag("minecraft:ice")?.clone();
    let mut new_y = pos[1];
    let mut min_y = 512;
    let top_y = new_y - 1;
    let mut area = 0;
    let (x0, x1) = (pos[0].min(corner[0]), pos[0].max(corner[0]));
    let (z0, z1) = (pos[2].min(corner[2]), pos[2].max(corner[2]));
    let bottom = c.region.min_y() + 1;
    for x in x0..=x1 {
        for z in z0..=z1 {
            let mut floor_y = pos[1] - 1;
            loop {
                let state = c.region.get([x, floor_y, z]);
                let fluid = table.fluid(state);
                let watery =
                    fluid == FLUID_WATER || fluid == super::super::blocks::FLUID_FLOWING_WATER;
                if !((table.is_air(state) || watery || table.in_tag(state, &ice))
                    && floor_y > bottom)
                {
                    break;
                }
                floor_y -= 1;
            }
            min_y = min_y.min(floor_y);
            if floor_y < top_y - 2 {
                area += 1;
            }
        }
    }
    let width = (pos[0] - corner[0]).abs();
    if top_y - min_y > 2 && area > width - 2 {
        new_y = min_y + 1;
    }
    Ok(new_y)
}

fn nether_fossil(t: &mut TemplatePiece, bbox: &mut BoundingBox, c: &mut Ctx) -> Result<(), String> {
    let location = t.name.clone();
    let size = template(c, &location)?.size;
    let settings = PlaceSettings::piece(
        Mirror::None,
        t.rotation,
        [0, 0, 0],
        vec![ignore(c, &["structure_block", "air"])?],
    );
    let fossil = template_box(size, t.position, t.rotation, [0, 0, 0], Mirror::None);
    // The fossil places whole from each chunk it reaches (`chunkBB.encapsulate`).
    c.chunk_box.encapsulate(&fossil);
    place_template(c, bbox, &location, t.position, settings, &mut |_, _, _| {
        Ok(())
    })?;
    // `placeDriedGhast`: from the seed at the fossil's centre.
    let (cx, cy, cz) = fossil.center();
    let mut random = Random::legacy(c.placer.seed)
        .fork_positional()
        .at(cx, cy, cz);
    if random.next_float() < 0.5 {
        let x = fossil.min_x + random.next_int_bounded(fossil.x_span());
        let z = fossil.min_z + random.next_int_bounded(fossil.z_span());
        let pos = [x, fossil.min_y, z];
        if c.placer.table.is_air(c.region.get(pos)) && c.chunk_box.is_inside(x, pos[1], z) {
            let rotation = super::super::template::ROTATIONS[random.next_int_bounded(4) as usize];
            let ghast = c.state("dried_ghast")?;
            let state = c.placer.transform(ghast, Mirror::None, rotation);
            c.set(pos, state, 2);
        }
    }
    Ok(())
}

fn end_city(
    t: &mut TemplatePiece,
    bbox: &mut BoundingBox,
    c: &mut Ctx,
    overwrite: bool,
) -> Result<(), String> {
    let location = format!("minecraft:end_city/{}", t.name);
    let ignored: &[&str] = if overwrite {
        &["structure_block"]
    } else {
        &["structure_block", "air"]
    };
    let mut settings = PlaceSettings::piece(
        Mirror::None,
        t.rotation,
        [0, 0, 0],
        vec![ignore(c, ignored)?],
    );
    settings.ignore_entities = true;
    let rotation = t.rotation;
    place_template(
        c,
        bbox,
        &location,
        t.position,
        settings,
        &mut |c, marker, pos| {
            if marker.starts_with("Chest") {
                let chest = [pos[0], pos[1] - 1, pos[2]];
                if c.chunk_box.is_inside(chest[0], chest[1], chest[2]) {
                    container_loot(c, chest, END_CITY_LOOT)?;
                }
            } else if c.chunk_box.is_inside(pos[0], pos[1], pos[2]) && spawnable(pos) {
                if marker.starts_with("Sentry") {
                    // Placed without turning: its yaw stays the random one it
                    // was created with.
                    c.region.add_entity(Entity {
                        kind: "minecraft:shulker",
                        pos: [pos[0] as f64 + 0.5, pos[1] as f64, pos[2] as f64 + 0.5],
                        yaw: f32::NAN,
                    });
                } else if marker.starts_with("Elytra") {
                    // An item frame on the block's south face as the piece is
                    // turned: a sixteenth of a block from the wall it hangs on.
                    let facing = rotate_direction(rotation, Direction::South);
                    let (dx, dz) = facing.step();
                    c.region.add_entity(Entity {
                        kind: "minecraft:item_frame",
                        pos: [
                            pos[0] as f64 + 0.5 - dx as f64 * 0.46875,
                            pos[1] as f64 + 0.5,
                            pos[2] as f64 + 0.5 - dz as f64 * 0.46875,
                        ],
                        yaw: (facing.data_2d() * 90) as f32,
                    });
                }
            }
            Ok(())
        },
    )
}

/// `Level.isInSpawnableBounds`.
fn spawnable(pos: [i32; 3]) -> bool {
    pos[0].abs() < 30_000_000
        && pos[2].abs() < 30_000_000
        && (-20_000_000..20_000_000).contains(&pos[1])
}

/// `Rotation.rotate(Direction)` of a horizontal direction.
fn rotate_direction(rotation: Rotation, d: Direction) -> Direction {
    match rotation {
        Rotation::None => d,
        Rotation::Clockwise90 => d.clockwise(),
        Rotation::Clockwise180 => d.opposite(),
        Rotation::Counterclockwise90 => d.counter_clockwise(),
    }
}

fn mansion(t: &mut TemplatePiece, bbox: &mut BoundingBox, c: &mut Ctx) -> Result<(), String> {
    let location = format!("minecraft:woodland_mansion/{}", t.name);
    let mut settings = PlaceSettings::piece(
        t.mirror,
        t.rotation,
        [0, 0, 0],
        vec![ignore(c, &["structure_block"])?],
    );
    settings.ignore_entities = true;
    let rotation = t.rotation;
    place_template(
        c,
        bbox,
        &location,
        t.position,
        settings,
        &mut |c, marker, pos| {
            if let Some(side) = marker.strip_prefix("Chest") {
                let chest = c.state("chest")?;
                let state = match side {
                    "West" => c.placer.with(
                        chest,
                        "facing",
                        rotate_direction(rotation, Direction::West).name(),
                    ),
                    "East" => c.placer.with(
                        chest,
                        "facing",
                        rotate_direction(rotation, Direction::East).name(),
                    ),
                    "South" => c.placer.with(
                        chest,
                        "facing",
                        rotate_direction(rotation, Direction::South).name(),
                    ),
                    "North" => c.placer.with(
                        chest,
                        "facing",
                        rotate_direction(rotation, Direction::North).name(),
                    ),
                    _ => chest,
                };
                c.create_chest(pos, MANSION_LOOT, Some(state))?;
                return Ok(());
            }
            let mobs: Vec<&str> = match marker {
                "Mage" => vec!["minecraft:evoker"],
                "Warrior" => vec!["minecraft:vindicator"],
                "Group of Allays" => {
                    let n = c.region.random.next_int_bounded(3) + 1;
                    vec!["minecraft:allay"; n as usize]
                }
                _ => return Ok(()),
            };
            for kind in mobs {
                c.region.add_entity(Entity {
                    kind: entity_kind(kind),
                    pos: [pos[0] as f64 + 0.5, pos[1] as f64, pos[2] as f64 + 0.5],
                    yaw: 0.0,
                });
                super::mobs::finalize(c, kind)?;
                c.set(pos, c.placer.air, 2);
            }
            Ok(())
        },
    )
}

/// `WoodlandMansionStructure.afterPlace`: cobblestone under the mansion's
/// pieces down to the ground, in the chunk.
pub fn mansion_after_place(pieces: &[Piece], c: &mut Ctx) -> Result<(), String> {
    let Some(bbox) = super::piece::encapsulating(pieces.iter().map(|p| &p.bbox)) else {
        return Ok(());
    };
    let table = c.placer.table;
    let cobblestone = c.state("cobblestone")?;
    let min_y = c.region.min_y();
    let y_start = bbox.min_y;
    let k = c.chunk_box;
    for x in k.min_x..=k.max_x {
        for z in k.min_z..=k.max_z {
            let top = [x, y_start, z];
            if table.is_air(c.region.get(top)) || !bbox.is_inside(x, y_start, z) {
                continue;
            }
            if !pieces.iter().any(|p| p.bbox.is_inside(x, y_start, z)) {
                continue;
            }
            let mut y = y_start - 1;
            while y > min_y {
                let state = c.region.get([x, y, z]);
                if !table.is_air(state) && !table.flag(state, super::super::blocks::LIQUID) {
                    break;
                }
                c.set([x, y, z], cobblestone, 2);
                y -= 1;
            }
        }
    }
    Ok(())
}

/// A ruined portal's placement properties (`RuinedPortalPiece.Properties`).
struct Portal {
    vertical: &'static str,
    cold: bool,
    air_pocket: bool,
    overgrown: bool,
    vines: bool,
}

impl Portal {
    /// `canBlockBeReplacedByNetherrackOrMagma`.
    fn replaceable(&self, c: &Ctx, state: u16) -> Result<bool, String> {
        let table = c.placer.table;
        Ok(!table.is_air(state)
            && !c.placer.is(state, "obsidian")
            && !table.in_tag(state, table.tag("minecraft:features_cannot_replace")?)
            && (self.vertical == "in_nether" || !c.placer.is(state, "lava")))
    }

    /// `placeNetherrackOrMagma`.
    fn netherrack_or_magma(&self, c: &mut Ctx, pos: [i32; 3]) -> Result<(), String> {
        let here = c.region.get(pos);
        if !self.replaceable(c, here)? {
            return Ok(());
        }
        let state = if !self.cold && c.random.next_float() < 0.07 {
            c.state("magma_block")?
        } else {
            c.state("netherrack")?
        };
        c.set(pos, state, 3);
        Ok(())
    }

    /// `addNetherrackDripColumn`.
    fn drip_column(&self, c: &mut Ctx, mut pos: [i32; 3]) -> Result<(), String> {
        self.netherrack_or_magma(c, pos)?;
        let mut remaining = 8;
        while remaining > 0 && c.random.next_float() < 0.5 {
            pos[1] -= 1;
            remaining -= 1;
            self.netherrack_or_magma(c, pos)?;
        }
        Ok(())
    }

    /// `maybeAddLeavesAbove`.
    fn leaves_above(&self, c: &mut Ctx, pos: [i32; 3]) -> Result<(), String> {
        let above = [pos[0], pos[1] + 1, pos[2]];
        if c.random.next_float() < 0.5
            && c.placer.is(c.region.get(pos), "netherrack")
            && c.placer.table.is_air(c.region.get(above))
        {
            let leaves = c.state("jungle_leaves[persistent=true]")?;
            c.set(above, leaves, 3);
        }
        Ok(())
    }

    /// `maybeAddVines`.
    fn vines(&self, c: &mut Ctx, pos: [i32; 3]) -> Result<(), String> {
        let table = c.placer.table;
        let state = c.region.get(pos);
        if table.is_air(state) || c.placer.is(state, "vine") {
            return Ok(());
        }
        let d = Direction::random(c.random);
        let (dx, dz) = d.step();
        let neighbour = [pos[0] + dx, pos[1], pos[2] + dz];
        if !table.is_air(c.region.get(neighbour)) {
            return Ok(());
        }
        // A full collision face toward the neighbour (bits by `Direction`
        // order: down, up, north, south, west, east).
        let face = match d {
            Direction::North => 2,
            Direction::South => 3,
            Direction::West => 4,
            Direction::East => 5,
        };
        if table.flag(state, super::super::blocks::COLLISION_FULL << face) {
            let vine = c.state("vine")?;
            let vine = c.placer.with(vine, d.opposite().name(), "true");
            c.set(neighbour, vine, 3);
        }
        Ok(())
    }
}

fn ruined_portal(t: &mut TemplatePiece, bbox: &mut BoundingBox, c: &mut Ctx) -> Result<(), String> {
    let TemplateKind::RuinedPortal {
        vertical_placement,
        cold,
        mossiness,
        air_pocket,
        overgrown,
        vines,
        replace_with_blackstone,
    } = t.kind.clone()
    else {
        unreachable!("a ruined portal piece");
    };
    let portal = Portal {
        vertical: vertical_placement,
        cold,
        air_pocket,
        overgrown,
        vines,
    };
    let location = t.name.clone();
    let size = template(c, &location)?.size;
    let pivot = [size[0] / 2, 0, size[2] / 2];
    let table = c.placer.table;
    let random_replace = |from: &str,
                          chance: f32,
                          to: &str|
     -> Result<super::super::template::ProcessorRule, String> {
        super::super::template::ProcessorRule::replace(table, from, Some(chance), to)
    };
    let mut rules = vec![random_replace("gold_block", 0.3, "air")?];
    rules.push(if vertical_placement == "on_ocean_floor" {
        super::super::template::ProcessorRule::replace(table, "lava", None, "magma_block")?
    } else if cold {
        super::super::template::ProcessorRule::replace(table, "lava", None, "netherrack")?
    } else {
        random_replace("lava", 0.2, "magma_block")?
    });
    if !cold {
        rules.push(random_replace("netherrack", 0.07, "magma_block")?);
    }
    let ignored: &[&str] = if portal.air_pocket {
        &["structure_block"]
    } else {
        &["structure_block", "air"]
    };
    let mut processors = vec![
        ignore(c, ignored)?,
        Processor::Rule(rules),
        Processor::BlockAge(mossiness),
        Processor::Protected(table.tag("minecraft:features_cannot_replace")?.clone()),
        Processor::LavaSubmerged,
    ];
    if replace_with_blackstone {
        processors.push(Processor::blackstone(table)?);
    }
    let settings = PlaceSettings::piece(t.mirror, t.rotation, pivot, processors);
    let portal_box = template_box(size, t.position, t.rotation, pivot, t.mirror);
    let (cx, cy, cz) = portal_box.center();
    if !c.chunk_box.is_inside(cx, cy, cz) {
        return Ok(());
    }
    // The whole portal is placed from the chunk holding its centre.
    c.chunk_box.encapsulate(&portal_box);
    place_template(c, bbox, &location, t.position, settings, &mut |_, _, _| {
        Ok(())
    })?;
    spread_netherrack(&portal, c, *bbox)?;
    // `addNetherrackDripColumnsBelowPortal`.
    let b = *bbox;
    for x in b.min_x + 1..b.max_x {
        for z in b.min_z + 1..b.max_z {
            let pos = [x, b.min_y, z];
            if c.placer.is(c.region.get(pos), "netherrack") {
                portal.drip_column(c, [x, b.min_y - 1, z])?;
            }
        }
    }
    if portal.vines || portal.overgrown {
        for z in b.min_z..=b.max_z {
            for y in b.min_y..=b.max_y {
                for x in b.min_x..=b.max_x {
                    if portal.vines {
                        portal.vines(c, [x, y, z])?;
                    }
                    if portal.overgrown {
                        portal.leaves_above(c, [x, y, z])?;
                    }
                }
            }
        }
    }
    Ok(())
}

/// `RuinedPortalPiece.spreadNetherrack`: netherrack (or magma) around the
/// portal's centre on the ground, thinning with distance.
fn spread_netherrack(portal: &Portal, c: &mut Ctx, b: BoundingBox) -> Result<(), String> {
    const PROBABILITY: [f64; 14] = [
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.9, 0.9, 0.8, 0.7, 0.6, 0.4, 0.2,
    ];
    let follow_ground = portal.vertical == "on_land_surface" || portal.vertical == "on_ocean_floor";
    let (cx, _, cz) = b.center();
    let max_distance = PROBABILITY.len() as i32;
    let average_width = (b.x_span() + b.z_span()) / 2;
    let adjustment = c.random.next_int_bounded((8 - average_width / 2).max(1));
    let heightmap = if portal.vertical == "on_ocean_floor" {
        Heightmap::OceanFloorWg
    } else {
        Heightmap::WorldSurfaceWg
    };
    for x in cx - max_distance..=cx + max_distance {
        for z in cz - max_distance..=cz + max_distance {
            let distance = (x - cx).abs() + (z - cz).abs();
            let adjusted = (distance + adjustment).max(0);
            if adjusted >= max_distance {
                continue;
            }
            // `nextDouble` against the table's floats, widened.
            if c.random.next_double() >= PROBABILITY[adjusted as usize] as f32 as f64 {
                continue;
            }
            let surface = c.region.height_at(heightmap, x, z) - 1;
            let y = if follow_ground {
                surface
            } else {
                b.min_y.min(surface)
            };
            let pos = [x, y, z];
            if (y - b.min_y).abs() > 3 {
                continue;
            }
            let here = c.region.get(pos);
            if portal.replaceable(c, here)? {
                portal.netherrack_or_magma(c, pos)?;
                if portal.overgrown {
                    portal.leaves_above(c, pos)?;
                }
                portal.drip_column(c, [x, y - 1, z])?;
            }
        }
    }
    Ok(())
}
