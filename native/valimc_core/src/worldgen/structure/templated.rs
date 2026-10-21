//! Template structures (VMC-025e2): igloos, shipwrecks, ocean ruins, ruined
//! portals, nether fossils and end cities, whose pieces are structure
//! templates (`TemplateStructurePiece`) placed by size, rotation, mirror and
//! pivot.

use super::super::blocks::Heightmap;
use super::super::json::Json;
use super::super::providers::{GenContext as HeightContext, HeightProvider};
use super::super::random::Random;
use super::super::surface;
use super::super::template::{transform, Mirror, Rotation, ROTATIONS};
use super::piece::{
    rotated, BoundingBox, Direction, Piece, PieceKind, TemplateKind, TemplatePiece,
};
use super::scattered::on_top_of_chunk_center;
use super::GenContext;

/// `StructureTemplate.getBoundingBox` of a template of `size`.
pub fn template_box(
    size: [i32; 3],
    position: [i32; 3],
    rotation: Rotation,
    pivot: [i32; 3],
    mirror: Mirror,
) -> BoundingBox {
    let a = transform([0, 0, 0], mirror, rotation, pivot);
    let b = transform(
        [size[0] - 1, size[1] - 1, size[2] - 1],
        mirror,
        rotation,
        pivot,
    );
    BoundingBox::new(a[0], a[1], a[2], b[0], b[1], b[2]).moved(
        position[0],
        position[1],
        position[2],
    )
}

/// A template piece of the template at `location`, saved under `name`.
#[allow(clippy::too_many_arguments)]
fn template_piece(
    gc: &GenContext,
    kind: TemplateKind,
    location: &str,
    name: &str,
    position: [i32; 3],
    rotation: Rotation,
    mirror: Mirror,
    pivot: [i32; 3],
) -> Result<Piece, String> {
    let size = gc.env.registry.template(location)?.size;
    Ok(Piece {
        kind: PieceKind::Template(TemplatePiece {
            kind,
            name: name.to_string(),
            position,
            rotation,
            mirror,
        }),
        bbox: template_box(size, position, rotation, pivot, mirror),
        orientation: Some(Direction::North),
        gen_depth: 0,
    })
}

fn random_rotation(random: &mut Random) -> Rotation {
    ROTATIONS[random.next_int_bounded(4) as usize]
}

/// `Mth.nextInt`.
fn next_int_between(random: &mut Random, min: i32, max: i32) -> i32 {
    if min >= max {
        min
    } else {
        random.next_int_bounded(max - min + 1) + min
    }
}

/// `Mth.randomBetweenInclusive`.
fn between_inclusive(random: &mut Random, min: i32, max: i32) -> i32 {
    random.next_int_bounded(max - min + 1) + min
}

fn pick<'a>(random: &mut Random, options: &[&'a str]) -> &'a str {
    options[random.next_int_bounded(options.len() as i32) as usize]
}

const IGLOO_TOP: &str = "minecraft:igloo/top";
const IGLOO_MIDDLE: &str = "minecraft:igloo/middle";
const IGLOO_BOTTOM: &str = "minecraft:igloo/bottom";

/// Igloos: the top at y 90, and half of the time a laboratory 4 to 11 ladders
/// below it.
pub fn igloo(gc: &mut GenContext) -> Result<Option<Vec<Piece>>, String> {
    if !on_top_of_chunk_center(gc, Heightmap::WorldSurfaceWg)? {
        return Ok(None);
    }
    let start = [gc.min_block_x(), 90, gc.min_block_z()];
    let rotation = random_rotation(&mut gc.random);
    let piece = |gc: &GenContext, location: &str, depth: i32| {
        let (pivot, offset) = match location {
            IGLOO_TOP => ([3, 5, 5], [0, 0, 0]),
            IGLOO_MIDDLE => ([1, 3, 1], [2, -3, 4]),
            _ => ([3, 6, 7], [0, -3, -2]),
        };
        let position = [
            start[0] + offset[0],
            start[1] + offset[1] - depth,
            start[2] + offset[2],
        ];
        template_piece(
            gc,
            TemplateKind::Igloo,
            location,
            location,
            position,
            rotation,
            Mirror::None,
            pivot,
        )
    };
    let mut pieces = Vec::new();
    if gc.random.next_double() < 0.5 {
        let depth = gc.random.next_int_bounded(8) + 4;
        pieces.push(piece(gc, IGLOO_BOTTOM, depth * 3)?);
        for i in 0..depth - 1 {
            pieces.push(piece(gc, IGLOO_MIDDLE, i * 3)?);
        }
    }
    pieces.push(piece(gc, IGLOO_TOP, 0)?);
    Ok(Some(pieces))
}

const SHIPWRECKS_BEACHED: [&str; 11] = [
    "minecraft:shipwreck/with_mast",
    "minecraft:shipwreck/sideways_full",
    "minecraft:shipwreck/sideways_fronthalf",
    "minecraft:shipwreck/sideways_backhalf",
    "minecraft:shipwreck/rightsideup_full",
    "minecraft:shipwreck/rightsideup_fronthalf",
    "minecraft:shipwreck/rightsideup_backhalf",
    "minecraft:shipwreck/with_mast_degraded",
    "minecraft:shipwreck/rightsideup_full_degraded",
    "minecraft:shipwreck/rightsideup_fronthalf_degraded",
    "minecraft:shipwreck/rightsideup_backhalf_degraded",
];

const SHIPWRECKS_OCEAN: [&str; 20] = [
    "minecraft:shipwreck/with_mast",
    "minecraft:shipwreck/upsidedown_full",
    "minecraft:shipwreck/upsidedown_fronthalf",
    "minecraft:shipwreck/upsidedown_backhalf",
    "minecraft:shipwreck/sideways_full",
    "minecraft:shipwreck/sideways_fronthalf",
    "minecraft:shipwreck/sideways_backhalf",
    "minecraft:shipwreck/rightsideup_full",
    "minecraft:shipwreck/rightsideup_fronthalf",
    "minecraft:shipwreck/rightsideup_backhalf",
    "minecraft:shipwreck/with_mast_degraded",
    "minecraft:shipwreck/upsidedown_full_degraded",
    "minecraft:shipwreck/upsidedown_fronthalf_degraded",
    "minecraft:shipwreck/upsidedown_backhalf_degraded",
    "minecraft:shipwreck/sideways_full_degraded",
    "minecraft:shipwreck/sideways_fronthalf_degraded",
    "minecraft:shipwreck/sideways_backhalf_degraded",
    "minecraft:shipwreck/rightsideup_full_degraded",
    "minecraft:shipwreck/rightsideup_fronthalf_degraded",
    "minecraft:shipwreck/rightsideup_backhalf_degraded",
];

/// Shipwrecks at y 90; a template larger than 32 blocks gets its height now
/// (the others when placed).
pub fn shipwreck(gc: &mut GenContext, beached: bool) -> Result<Option<Vec<Piece>>, String> {
    let heightmap = if beached {
        Heightmap::WorldSurfaceWg
    } else {
        Heightmap::OceanFloorWg
    };
    if !on_top_of_chunk_center(gc, heightmap)? {
        return Ok(None);
    }
    let rotation = random_rotation(&mut gc.random);
    let offset = [gc.min_block_x(), 90, gc.min_block_z()];
    let options: &[&str] = if beached {
        &SHIPWRECKS_BEACHED
    } else {
        &SHIPWRECKS_OCEAN
    };
    let location = pick(&mut gc.random, options);
    let mut piece = template_piece(
        gc,
        TemplateKind::Shipwreck {
            beached,
            height_adjusted: false,
        },
        location,
        location,
        offset,
        rotation,
        Mirror::None,
        [4, 0, 15],
    )?;
    let size = gc.env.registry.template(location)?.size;
    if size[0] > 32 || size[1] > 32 {
        let bb = piece.bbox;
        let height = if beached {
            // Vanilla passes the box's X span as its minimum Z and the
            // minimum Z as its X size.
            let min_y = gc.lowest_y(bb.min_x, bb.x_span(), bb.min_z, bb.z_span())?;
            min_y - size[1] / 2 - gc.random.next_int_bounded(3)
        } else {
            gc.mean_first_occupied_height(bb.min_x, bb.x_span(), bb.min_z, bb.z_span())?
        };
        if let PieceKind::Template(t) = &mut piece.kind {
            t.position[1] = height;
            t.kind = TemplateKind::Shipwreck {
                beached,
                height_adjusted: true,
            };
        }
    }
    Ok(Some(vec![piece]))
}

const WARM_RUINS: [&str; 8] = [
    "minecraft:underwater_ruin/warm_1",
    "minecraft:underwater_ruin/warm_2",
    "minecraft:underwater_ruin/warm_3",
    "minecraft:underwater_ruin/warm_4",
    "minecraft:underwater_ruin/warm_5",
    "minecraft:underwater_ruin/warm_6",
    "minecraft:underwater_ruin/warm_7",
    "minecraft:underwater_ruin/warm_8",
];
const BIG_WARM_RUINS: [&str; 4] = [
    "minecraft:underwater_ruin/big_warm_4",
    "minecraft:underwater_ruin/big_warm_5",
    "minecraft:underwater_ruin/big_warm_6",
    "minecraft:underwater_ruin/big_warm_7",
];
const COLD_RUINS: [&str; 3] = ["brick", "cracked", "mossy"];
const SMALL_COLD: [&str; 8] = ["1", "2", "3", "4", "5", "6", "7", "8"];
const BIG_COLD: [&str; 4] = ["1", "2", "3", "8"];

fn ocean_ruin_piece(
    gc: &mut GenContext,
    position: [i32; 3],
    rotation: Rotation,
    warm: bool,
    large: bool,
    integrity: f32,
    pieces: &mut Vec<Piece>,
) -> Result<(), String> {
    let mut add = |gc: &GenContext, location: &str, integrity: f32| -> Result<(), String> {
        pieces.push(template_piece(
            gc,
            TemplateKind::OceanRuin {
                integrity,
                warm,
                large,
            },
            location,
            location,
            position,
            rotation,
            Mirror::None,
            [0, 0, 0],
        )?);
        Ok(())
    };
    if warm {
        let location = if large {
            pick(&mut gc.random, &BIG_WARM_RUINS)
        } else {
            pick(&mut gc.random, &WARM_RUINS)
        };
        return add(gc, location, integrity);
    }
    let numbers: &[&str] = if large { &BIG_COLD } else { &SMALL_COLD };
    let index = gc.random.next_int_bounded(numbers.len() as i32) as usize;
    for (kind, integrity) in COLD_RUINS.iter().zip([integrity, 0.7, 0.5]) {
        let location = format!(
            "minecraft:underwater_ruin/{}{kind}_{}",
            if large { "big_" } else { "" },
            numbers[index]
        );
        add(gc, &location, integrity)?;
    }
    Ok(())
}

/// Ocean ruins at y 90: one ruin, large ones sometimes with a cluster of
/// small ruins around.
pub fn ocean_ruin(
    gc: &mut GenContext,
    warm: bool,
    large_probability: f32,
    cluster_probability: f32,
) -> Result<Option<Vec<Piece>>, String> {
    if !on_top_of_chunk_center(gc, Heightmap::OceanFloorWg)? {
        return Ok(None);
    }
    let p = [gc.min_block_x(), 90, gc.min_block_z()];
    let rotation = random_rotation(&mut gc.random);
    let mut pieces = Vec::new();
    let large = gc.random.next_float() <= large_probability;
    let integrity = if large { 0.9 } else { 0.8 };
    ocean_ruin_piece(gc, p, rotation, warm, large, integrity, &mut pieces)?;
    if large && gc.random.next_float() <= cluster_probability {
        let corner = transform([15, 0, 15], Mirror::None, rotation, [0, 0, 0]);
        let corner = [corner[0] + p[0], 90, corner[2] + p[2]];
        let parent = BoundingBox::new(p[0], 90, p[2], corner[0], corner[1], corner[2]);
        let (ox, oz) = (p[0].min(corner[0]), p[2].min(corner[2]));
        let r = &mut gc.random;
        let mut offsets = Vec::with_capacity(8);
        for (x, z) in [
            ((-16, 1, 8), (16, 1, 7)),
            ((-16, 1, 8), (0, 1, 7)),
            ((-16, 1, 8), (-16, 4, 8)),
            ((0, 1, 7), (16, 1, 7)),
            ((0, 1, 7), (-16, 4, 6)),
            ((16, 1, 7), (16, 3, 8)),
            ((16, 1, 7), (0, 1, 7)),
            ((16, 1, 7), (-16, 4, 8)),
        ] {
            let dx = x.0 + next_int_between(r, x.1, x.2);
            let dz = z.0 + next_int_between(r, z.1, z.2);
            offsets.push([ox + dx, 90, oz + dz]);
        }
        let ruins = next_int_between(&mut gc.random, 4, 8);
        for _ in 0..ruins {
            if offsets.is_empty() {
                continue;
            }
            let index = gc.random.next_int_bounded(offsets.len() as i32) as usize;
            let pos = offsets.remove(index);
            let next_rotation = random_rotation(&mut gc.random);
            let corner = transform([5, 0, 6], Mirror::None, next_rotation, [0, 0, 0]);
            let next = BoundingBox::new(
                pos[0],
                pos[1],
                pos[2],
                pos[0] + corner[0],
                pos[1] + corner[1],
                pos[2] + corner[2],
            );
            if !next.intersects(&parent) {
                ocean_ruin_piece(gc, pos, next_rotation, warm, false, 0.8, &mut pieces)?;
            }
        }
    }
    Ok(Some(pieces))
}

/// `RuinedPortalPiece.VerticalPlacement`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Vertical {
    OnLandSurface,
    PartlyBuried,
    OnOceanFloor,
    InMountain,
    Underground,
    InNether,
}

impl Vertical {
    fn name(self) -> &'static str {
        match self {
            Vertical::OnLandSurface => "on_land_surface",
            Vertical::PartlyBuried => "partly_buried",
            Vertical::OnOceanFloor => "on_ocean_floor",
            Vertical::InMountain => "in_mountain",
            Vertical::Underground => "underground",
            Vertical::InNether => "in_nether",
        }
    }

    fn heightmap(self) -> Heightmap {
        if self == Vertical::OnOceanFloor {
            Heightmap::OceanFloorWg
        } else {
            Heightmap::WorldSurfaceWg
        }
    }
}

/// `RuinedPortalStructure.Setup`.
#[derive(Clone, Debug)]
pub struct PortalSetup {
    pub placement: Vertical,
    pub air_pocket_probability: f32,
    pub mossiness: f32,
    pub overgrown: bool,
    pub vines: bool,
    pub can_be_cold: bool,
    pub replace_with_blackstone: bool,
    pub weight: f32,
}

impl PortalSetup {
    pub fn parse(json: &Json) -> Result<PortalSetup, String> {
        let float = |k: &str| -> Result<f32, String> { Ok(json.field(k)?.as_f64()? as f32) };
        let flag = |k: &str| -> Result<bool, String> { json.field(k)?.as_bool() };
        Ok(PortalSetup {
            placement: match json.field("placement")?.as_str()? {
                "on_land_surface" => Vertical::OnLandSurface,
                "partly_buried" => Vertical::PartlyBuried,
                "on_ocean_floor" => Vertical::OnOceanFloor,
                "in_mountain" => Vertical::InMountain,
                "underground" => Vertical::Underground,
                "in_nether" => Vertical::InNether,
                other => return Err(format!("unknown vertical placement {other}")),
            },
            air_pocket_probability: float("air_pocket_probability")?,
            mossiness: float("mossiness")?,
            overgrown: flag("overgrown")?,
            vines: flag("vines")?,
            can_be_cold: flag("can_be_cold")?,
            replace_with_blackstone: flag("replace_with_blackstone")?,
            weight: float("weight")?,
        })
    }
}

const PORTALS: [&str; 10] = [
    "minecraft:ruined_portal/portal_1",
    "minecraft:ruined_portal/portal_2",
    "minecraft:ruined_portal/portal_3",
    "minecraft:ruined_portal/portal_4",
    "minecraft:ruined_portal/portal_5",
    "minecraft:ruined_portal/portal_6",
    "minecraft:ruined_portal/portal_7",
    "minecraft:ruined_portal/portal_8",
    "minecraft:ruined_portal/portal_9",
    "minecraft:ruined_portal/portal_10",
];
const GIANT_PORTALS: [&str; 3] = [
    "minecraft:ruined_portal/giant_portal_1",
    "minecraft:ruined_portal/giant_portal_2",
    "minecraft:ruined_portal/giant_portal_3",
];

/// Ruined portals: a setup by weight, the template, rotation and mirror,
/// then a height where three of the box's bottom corners stand on ground.
pub fn ruined_portal(
    gc: &mut GenContext,
    setups: &[PortalSetup],
) -> Result<Option<Vec<Piece>>, String> {
    let setup = if setups.len() > 1 {
        let total: f32 = setups.iter().map(|s| s.weight).sum();
        let mut pick_value = gc.random.next_float();
        let mut chosen = None;
        for s in setups {
            pick_value -= s.weight / total;
            if pick_value < 0.0 {
                chosen = Some(s);
                break;
            }
        }
        chosen.ok_or("no ruined portal setup chosen")?
    } else {
        setups.first().ok_or("a ruined portal needs a setup")?
    };
    let air_pocket = match setup.air_pocket_probability {
        0.0 => false,
        1.0 => true,
        limit => gc.random.next_float() < limit,
    };
    let location = if gc.random.next_float() < 0.05 {
        pick(&mut gc.random, &GIANT_PORTALS)
    } else {
        pick(&mut gc.random, &PORTALS)
    };
    let size = gc.env.registry.template(location)?.size;
    let rotation = random_rotation(&mut gc.random);
    let mirror = if gc.random.next_float() < 0.5 {
        Mirror::None
    } else {
        Mirror::FrontBack
    };
    let pivot = [size[0] / 2, 0, size[2] / 2];
    let base = [gc.min_block_x(), 0, gc.min_block_z()];
    let bbox = template_box(size, base, rotation, pivot, mirror);
    let (cx, _, cz) = bbox.center();
    let surface_y = gc.base_height(cx, cz, setup.placement.heightmap())? - 1;
    let projected_y = suitable_y(
        gc,
        setup.placement,
        air_pocket,
        surface_y,
        bbox.y_span(),
        &bbox,
    )?;
    let origin = (base[0], projected_y, base[2]);
    if !gc.is_valid_biome(origin) {
        return Ok(None);
    }
    let sea_level = gc.sea_level();
    let biome = gc
        .env
        .biomes
        .point(gc.ctx, origin.0 >> 2, origin.1 >> 2, origin.2 >> 2);
    let cold = setup.can_be_cold
        && surface::temperature(
            &gc.env.climates[biome as usize],
            origin.0,
            origin.1,
            origin.2,
            sea_level,
        ) < 0.15;
    let piece = template_piece(
        gc,
        TemplateKind::RuinedPortal {
            vertical_placement: setup.placement.name(),
            cold,
            mossiness: setup.mossiness,
            air_pocket,
            overgrown: setup.overgrown,
            vines: setup.vines,
            replace_with_blackstone: setup.replace_with_blackstone,
        },
        location,
        location,
        [origin.0, origin.1, origin.2],
        rotation,
        mirror,
        pivot,
    )?;
    Ok(Some(vec![piece]))
}

/// `RuinedPortalStructure.findSuitableY`.
fn suitable_y(
    gc: &mut GenContext,
    placement: Vertical,
    air_pocket: bool,
    surface_y: i32,
    y_span: i32,
    bbox: &BoundingBox,
) -> Result<i32, String> {
    let min_y = gc.env.heights.level_min_y + 15;
    let r = &mut gc.random;
    let within = |r: &mut Random, min: i32, max: i32| {
        if min < max {
            between_inclusive(r, min, max)
        } else {
            max
        }
    };
    let new_y = match placement {
        Vertical::InNether => {
            if air_pocket {
                between_inclusive(r, 32, 100)
            } else if r.next_float() < 0.5 {
                between_inclusive(r, 27, 29)
            } else {
                between_inclusive(r, 29, 100)
            }
        }
        Vertical::InMountain => within(r, 70, surface_y - y_span),
        Vertical::Underground => within(r, min_y, surface_y - y_span),
        Vertical::PartlyBuried => surface_y - y_span + between_inclusive(r, 2, 8),
        Vertical::OnLandSurface | Vertical::OnOceanFloor => surface_y,
    };
    let columns = [
        gc.base_column(bbox.min_x, bbox.min_z)?,
        gc.base_column(bbox.max_x, bbox.min_z)?,
        gc.base_column(bbox.min_x, bbox.max_z)?,
        gc.base_column(bbox.max_x, bbox.max_z)?,
    ];
    let flags = &gc.env.heights.flags;
    let ocean_floor = placement == Vertical::OnOceanFloor;
    let opaque = |state: u16| {
        let f = flags[state as usize];
        if ocean_floor {
            f & 3 == 0
        } else {
            f & 1 == 0
        }
    };
    let mut projected = new_y;
    while projected > min_y {
        let mut on_ground = 0;
        for column in &columns {
            if opaque(column.block(projected)) {
                on_ground += 1;
                if on_ground == 3 {
                    return Ok(projected);
                }
            }
        }
        projected -= 1;
    }
    Ok(projected)
}

const NETHER_FOSSILS: [&str; 14] = [
    "minecraft:nether_fossils/fossil_1",
    "minecraft:nether_fossils/fossil_2",
    "minecraft:nether_fossils/fossil_3",
    "minecraft:nether_fossils/fossil_4",
    "minecraft:nether_fossils/fossil_5",
    "minecraft:nether_fossils/fossil_6",
    "minecraft:nether_fossils/fossil_7",
    "minecraft:nether_fossils/fossil_8",
    "minecraft:nether_fossils/fossil_9",
    "minecraft:nether_fossils/fossil_10",
    "minecraft:nether_fossils/fossil_11",
    "minecraft:nether_fossils/fossil_12",
    "minecraft:nether_fossils/fossil_13",
    "minecraft:nether_fossils/fossil_14",
];

/// Nether fossils: a random column of the chunk, a height from the provider,
/// then down to the first air above ground above sea level. In a noise
/// column only the default block (netherrack) is sturdy; soul sand never
/// occurs there.
pub fn nether_fossil(
    gc: &mut GenContext,
    height: &HeightProvider,
) -> Result<Option<Vec<Piece>>, String> {
    let x = gc.min_block_x() + gc.random.next_int_bounded(16);
    let z = gc.min_block_z() + gc.random.next_int_bounded(16);
    let heights = &gc.env.heights;
    let sea_level = heights.sea_level;
    let context = HeightContext {
        min_y: heights.level_min_y.max(heights.min_y),
        height: heights.level_height.min(heights.height),
        sea_level,
    };
    let mut y = height.sample(&mut gc.random, context);
    let column = gc.base_column(x, z)?;
    let heights = &gc.env.heights;
    let ground = heights.blocks.default_block;
    let flags = &heights.flags;
    while y > sea_level {
        let current = column.block(y);
        y -= 1;
        if flags[current as usize] & 1 != 0 && column.block(y) == ground {
            break;
        }
    }
    if y <= sea_level {
        return Ok(None);
    }
    if !gc.is_valid_biome((x, y, z)) {
        return Ok(None);
    }
    let rotation = random_rotation(&mut gc.random);
    let location = pick(&mut gc.random, &NETHER_FOSSILS);
    let piece = template_piece(
        gc,
        TemplateKind::NetherFossil,
        location,
        location,
        [x, y, z],
        rotation,
        Mirror::None,
        [0, 0, 0],
    )?;
    Ok(Some(vec![piece]))
}

/// End cities (`EndCityStructure`, `EndCityPieces`).
pub fn end_city(gc: &mut GenContext) -> Result<Option<Vec<Piece>>, String> {
    let (x, z) = (gc.min_block_x() + 7, gc.min_block_z() + 7);
    if !gc.could_exist_in_terrain_column(x, z)? {
        return Ok(None);
    }
    let rotation = random_rotation(&mut gc.random);
    let (dx, dz) = match rotation {
        Rotation::None => (5, 5),
        Rotation::Clockwise90 => (-5, 5),
        Rotation::Clockwise180 => (-5, -5),
        Rotation::Counterclockwise90 => (5, -5),
    };
    let y = gc.lowest_y(x, z, dx, dz)?;
    if y < 60 || !gc.is_valid_biome((x, y, z)) {
        return Ok(None);
    }
    let mut city = EndCity {
        gc,
        ship_created: false,
    };
    let mut pieces = Vec::new();
    let mut last = city.add(
        &mut pieces,
        city.piece("base_floor", [x, y, z], rotation, true)?,
    );
    for (offset, name, overwrite) in [
        ([-1, 0, -1], "second_floor_1", false),
        ([-1, 4, -1], "third_floor_1", false),
        ([-1, 8, -1], "third_roof", true),
    ] {
        let piece = city.attach(&pieces[last], offset, name, rotation, overwrite)?;
        last = city.add(&mut pieces, piece);
    }
    let parent = pieces[last].clone();
    city.recursive_children(Section::Tower, 1, &parent, None, &mut pieces)?;
    Ok(Some(pieces))
}

#[derive(Clone, Copy)]
enum Section {
    HouseTower,
    Tower,
    TowerBridge,
    FatTower,
}

const TOWER_BRIDGES: [(Rotation, [i32; 3]); 4] = [
    (Rotation::None, [1, -1, 0]),
    (Rotation::Clockwise90, [6, -1, 1]),
    (Rotation::Counterclockwise90, [0, -1, 5]),
    (Rotation::Clockwise180, [5, -1, 6]),
];

const FAT_TOWER_BRIDGES: [(Rotation, [i32; 3]); 4] = [
    (Rotation::None, [4, -1, 0]),
    (Rotation::Clockwise90, [12, -1, 4]),
    (Rotation::Counterclockwise90, [0, -1, 8]),
    (Rotation::Clockwise180, [8, -1, 12]),
];

struct EndCity<'a, 'b> {
    gc: &'a mut GenContext<'b>,
    ship_created: bool,
}

fn template_of(piece: &Piece) -> &TemplatePiece {
    match &piece.kind {
        PieceKind::Template(t) => t,
        _ => unreachable!("end city pieces are template pieces"),
    }
}

impl EndCity<'_, '_> {
    fn piece(
        &self,
        name: &str,
        position: [i32; 3],
        rotation: Rotation,
        overwrite: bool,
    ) -> Result<Piece, String> {
        template_piece(
            self.gc,
            TemplateKind::EndCity { overwrite },
            &format!("minecraft:end_city/{name}"),
            name,
            position,
            rotation,
            Mirror::None,
            [0, 0, 0],
        )
    }

    /// `EndCityPieces.addPiece`: a piece at the parent's template position,
    /// moved by the offset in the parent's rotation.
    fn attach(
        &self,
        parent: &Piece,
        offset: [i32; 3],
        name: &str,
        rotation: Rotation,
        overwrite: bool,
    ) -> Result<Piece, String> {
        let p = template_of(parent);
        let mut child = self.piece(name, p.position, rotation, overwrite)?;
        let origin = transform(offset, Mirror::None, p.rotation, [0, 0, 0]);
        child.moved_by(origin[0], origin[1], origin[2]);
        Ok(child)
    }

    fn add(&self, pieces: &mut Vec<Piece>, piece: Piece) -> usize {
        pieces.push(piece);
        pieces.len() - 1
    }

    /// Attaches a piece to `pieces[parent]` and adds it.
    fn grow(
        &self,
        pieces: &mut Vec<Piece>,
        parent: usize,
        offset: [i32; 3],
        name: &str,
        rotation: Rotation,
    ) -> Result<usize, String> {
        let piece = self.attach(&pieces[parent], offset, name, rotation, true)?;
        Ok(self.add(pieces, piece))
    }

    fn random(&mut self) -> &mut Random {
        &mut self.gc.random
    }

    /// `recursiveChildren`: a section's pieces join `pieces` (all tagged
    /// with one random depth) unless the first piece of `pieces` that one of
    /// them meets belongs to another branch than the parent.
    fn recursive_children(
        &mut self,
        section: Section,
        depth: i32,
        parent: &Piece,
        offset: Option<[i32; 3]>,
        pieces: &mut Vec<Piece>,
    ) -> Result<bool, String> {
        if depth > 8 {
            return Ok(false);
        }
        let mut children = Vec::new();
        if self.generate(section, depth, parent, offset, &mut children)? {
            let tag = self.random().next_int();
            let mut collision = false;
            for child in &mut children {
                child.gen_depth = tag;
                if let Some(other) = pieces.iter().find(|p| p.bbox.intersects(&child.bbox)) {
                    if other.gen_depth != parent.gen_depth {
                        collision = true;
                        break;
                    }
                }
            }
            if !collision {
                pieces.extend(children);
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn generate(
        &mut self,
        section: Section,
        depth: i32,
        parent: &Piece,
        offset: Option<[i32; 3]>,
        pieces: &mut Vec<Piece>,
    ) -> Result<bool, String> {
        let rotation = template_of(parent).rotation;
        match section {
            Section::HouseTower => {
                if depth > 8 {
                    return Ok(false);
                }
                let offset = offset.ok_or("a house tower needs an offset")?;
                let first = self.attach(parent, offset, "base_floor", rotation, true)?;
                let mut last = self.add(pieces, first);
                match self.random().next_int_bounded(3) {
                    0 => {
                        self.grow(pieces, last, [-1, 4, -1], "base_roof", rotation)?;
                    }
                    floors => {
                        let piece = self.attach(
                            &pieces[last],
                            [-1, 0, -1],
                            "second_floor_2",
                            rotation,
                            false,
                        )?;
                        last = self.add(pieces, piece);
                        if floors == 1 {
                            let piece = self.attach(
                                &pieces[last],
                                [-1, 8, -1],
                                "second_roof",
                                rotation,
                                false,
                            )?;
                            last = self.add(pieces, piece);
                        } else {
                            let piece = self.attach(
                                &pieces[last],
                                [-1, 4, -1],
                                "third_floor_2",
                                rotation,
                                false,
                            )?;
                            last = self.add(pieces, piece);
                            last = self.grow(pieces, last, [-1, 8, -1], "third_roof", rotation)?;
                        }
                        let parent = pieces[last].clone();
                        self.recursive_children(Section::Tower, depth + 1, &parent, None, pieces)?;
                    }
                }
                Ok(true)
            }
            Section::Tower => {
                let bx = 3 + self.random().next_int_bounded(2);
                let bz = 3 + self.random().next_int_bounded(2);
                let base = self.attach(parent, [bx, -3, bz], "tower_base", rotation, true)?;
                let mut last = self.add(pieces, base);
                last = self.grow(pieces, last, [0, 7, 0], "tower_piece", rotation)?;
                let mut bridge = if self.random().next_int_bounded(3) == 0 {
                    Some(last)
                } else {
                    None
                };
                let tower_height = 1 + self.random().next_int_bounded(3);
                for i in 0..tower_height {
                    last = self.grow(pieces, last, [0, 4, 0], "tower_piece", rotation)?;
                    if i < tower_height - 1 && self.random().next_bool() {
                        bridge = Some(last);
                    }
                }
                if let Some(bridge) = bridge {
                    for (turn, position) in TOWER_BRIDGES {
                        if self.random().next_bool() {
                            let start = self.grow(
                                pieces,
                                bridge,
                                position,
                                "bridge_end",
                                rotated(rotation, turn),
                            )?;
                            let parent = pieces[start].clone();
                            self.recursive_children(
                                Section::TowerBridge,
                                depth + 1,
                                &parent,
                                None,
                                pieces,
                            )?;
                        }
                    }
                } else if depth != 7 {
                    let parent = pieces[last].clone();
                    return self.recursive_children(
                        Section::FatTower,
                        depth + 1,
                        &parent,
                        None,
                        pieces,
                    );
                }
                self.grow(pieces, last, [-1, 4, -1], "tower_top", rotation)?;
                Ok(true)
            }
            Section::TowerBridge => {
                let length = self.random().next_int_bounded(4) + 1;
                let first = self.attach(parent, [0, 0, -4], "bridge_piece", rotation, true)?;
                let mut last = self.add(pieces, first);
                pieces[last].gen_depth = -1;
                let mut next_y = 0;
                for _ in 0..length {
                    if self.random().next_bool() {
                        last =
                            self.grow(pieces, last, [0, next_y, -4], "bridge_piece", rotation)?;
                        next_y = 0;
                    } else {
                        last = if self.random().next_bool() {
                            self.grow(
                                pieces,
                                last,
                                [0, next_y, -4],
                                "bridge_steep_stairs",
                                rotation,
                            )?
                        } else {
                            self.grow(
                                pieces,
                                last,
                                [0, next_y, -8],
                                "bridge_gentle_stairs",
                                rotation,
                            )?
                        };
                        next_y = 4;
                    }
                }
                if !self.ship_created && self.random().next_int_bounded(10 - depth) == 0 {
                    let sx = -8 + self.random().next_int_bounded(8);
                    let sz = -70 + self.random().next_int_bounded(10);
                    self.grow(pieces, last, [sx, next_y, sz], "ship", rotation)?;
                    self.ship_created = true;
                } else {
                    let parent = pieces[last].clone();
                    if !self.recursive_children(
                        Section::HouseTower,
                        depth + 1,
                        &parent,
                        Some([-3, next_y + 1, -11]),
                        pieces,
                    )? {
                        return Ok(false);
                    }
                }
                let end = self.grow(
                    pieces,
                    last,
                    [4, next_y, 0],
                    "bridge_end",
                    rotated(rotation, Rotation::Clockwise180),
                )?;
                pieces[end].gen_depth = -1;
                Ok(true)
            }
            Section::FatTower => {
                let base = self.attach(parent, [-3, 4, -3], "fat_tower_base", rotation, true)?;
                let mut last = self.add(pieces, base);
                last = self.grow(pieces, last, [0, 4, 0], "fat_tower_middle", rotation)?;
                let mut i = 0;
                while i < 2 && self.random().next_int_bounded(3) != 0 {
                    last = self.grow(pieces, last, [0, 8, 0], "fat_tower_middle", rotation)?;
                    for (turn, position) in FAT_TOWER_BRIDGES {
                        if self.random().next_bool() {
                            let start = self.grow(
                                pieces,
                                last,
                                position,
                                "bridge_end",
                                rotated(rotation, turn),
                            )?;
                            let parent = pieces[start].clone();
                            self.recursive_children(
                                Section::TowerBridge,
                                depth + 1,
                                &parent,
                                None,
                                pieces,
                            )?;
                        }
                    }
                    i += 1;
                }
                self.grow(pieces, last, [-2, 8, -2], "fat_tower_top", rotation)?;
                Ok(true)
            }
        }
    }
}
