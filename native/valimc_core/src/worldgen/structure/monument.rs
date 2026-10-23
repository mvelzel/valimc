//! Ocean monuments (VMC-025e5, `OceanMonumentStructure`): every biome within
//! 29 blocks of the chunk's (9, sea level, 9) must be an ocean or river, then
//! the building at y 39 facing a random direction. A start saves only the
//! building; vanilla rebuilds its rooms from the seed when it loads one, and
//! ValiMC keeps them with the building (VMC-025f).

use super::super::blocks::Heightmap;
use super::super::plants::shuffle;
use super::super::random::Random;
use super::super::region::Entity;
use super::piece::{make_bounding_box, BoundingBox, Direction, Piece, PieceKind};
use super::place::{Ctx, Frame};
use super::scattered::on_top_of_chunk_center;
use super::{BiomeSet, GenContext};

pub fn generate(gc: &mut GenContext, surrounding: &BiomeSet) -> Result<Option<Vec<Piece>>, String> {
    let (x, z) = (gc.min_block_x() + 9, gc.min_block_z() + 9);
    let y = gc.sea_level();
    // `BiomeResolver.getBiomesWithin`: every quart of the box.
    for qz in (z - 29) >> 2..=(z + 29) >> 2 {
        for qx in (x - 29) >> 2..=(x + 29) >> 2 {
            for qy in (y - 29) >> 2..=(y + 29) >> 2 {
                if !surrounding.contains(gc.env.biomes.point(gc.ctx, qx, qy, qz)) {
                    return Ok(None);
                }
            }
        }
    }
    if !on_top_of_chunk_center(gc, Heightmap::OceanFloorWg)? {
        return Ok(None);
    }
    let direction = Direction::random(&mut gc.random);
    let (west, north) = (gc.min_block_x() - 29, gc.min_block_z() - 29);
    let bbox = make_bounding_box(west, 39, north, direction, 58, 23, 58);
    let building = Building::new(&mut gc.random, bbox, direction);
    Ok(Some(vec![Piece {
        kind: PieceKind::Monument(Box::new(building)),
        bbox,
        orientation: Some(direction),
        gen_depth: 0,
    }]))
}

// Placement (VMC-025f4): the building's rooms, rebuilt from the generation
// random as `MonumentBuilding`'s constructor does, and each one's
// `postProcess`.

const DOWN: usize = 0;
const UP: usize = 1;
const NORTH: usize = 2;
const SOUTH: usize = 3;
const WEST: usize = 4;
const EAST: usize = 5;
/// `Direction` steps (down, up, north, south, west, east).
const STEP: [(i32, i32, i32); 6] = [
    (0, -1, 0),
    (0, 1, 0),
    (0, 0, -1),
    (0, 0, 1),
    (-1, 0, 0),
    (1, 0, 0),
];

fn room_index(x: i32, y: i32, z: i32) -> i32 {
    y * 25 + z * 5 + x
}

/// A grid cell of the building (`RoomDefinition`): its index, neighbours,
/// open sides and what the room fitting has claimed.
#[derive(Clone, Debug, PartialEq)]
pub struct RoomDef {
    pub index: i32,
    pub conn: [Option<usize>; 6],
    pub open: [bool; 6],
    claimed: bool,
    source: bool,
    scan: i32,
}

impl RoomDef {
    fn new(index: i32) -> RoomDef {
        RoomDef {
            index,
            conn: [None; 6],
            open: [false; 6],
            claimed: false,
            source: false,
            scan: 0,
        }
    }

    pub fn count_openings(&self) -> usize {
        self.open.iter().filter(|&&o| o).count()
    }
}

fn connect(defs: &mut [RoomDef], a: usize, d: usize, b: usize) {
    defs[a].conn[d] = Some(b);
    defs[b].conn[d ^ 1] = Some(a);
}

/// `findSource`: whether the room reaches the entrance through open sides.
fn find_source(defs: &mut [RoomDef], room: usize, scan: i32) -> bool {
    if defs[room].source {
        return true;
    }
    defs[room].scan = scan;
    for i in 0..6 {
        if let Some(next) = defs[room].conn[i] {
            if defs[room].open[i] && defs[next].scan != scan && find_source(defs, next, scan) {
                return true;
            }
        }
    }
    false
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum RoomKind {
    Entry,
    Core,
    DoubleX,
    DoubleXy,
    DoubleY,
    DoubleYz,
    DoubleZ,
    Simple(i32),
    SimpleTop,
    Wing(i32),
    Penthouse,
}

/// A child piece: its kind, box and grid cell (none for the wings and the
/// penthouse).
#[derive(Clone, Debug, PartialEq)]
struct Room {
    kind: RoomKind,
    bbox: BoundingBox,
    def: Option<usize>,
}

/// The building's rooms (not saved: vanilla rebuilds them from the seed).
#[derive(Clone, Debug, PartialEq)]
pub struct Building {
    defs: Vec<RoomDef>,
    rooms: Vec<Room>,
}

/// `OceanMonumentPiece.makeBoundingBox` of a grid room `w` × `h` × `d`
/// cells large.
fn room_box(orientation: Direction, index: i32, w: i32, h: i32, d: i32) -> BoundingBox {
    let (x, z, y) = (index % 5, index / 5 % 5, index / 25);
    let b = make_bounding_box(0, 0, 0, orientation, w * 8, h * 4, d * 8);
    match orientation {
        Direction::North => b.moved(x * 8, y * 4, -(z + d) * 8 + 1),
        Direction::South => b.moved(x * 8, y * 4, z * 8),
        Direction::West => b.moved(-(z + d) * 8 + 1, y * 4, x * 8),
        Direction::East => b.moved(z * 8, y * 4, x * 8),
    }
}

impl Building {
    /// `MonumentBuilding`'s constructor after its direction.
    pub fn new(random: &mut Random, bbox: BoundingBox, direction: Direction) -> Building {
        let mut defs: Vec<RoomDef> = Vec::new();
        let mut grid: [Option<usize>; 75] = [None; 75];
        let add =
            |defs: &mut Vec<RoomDef>, grid: &mut [Option<usize>; 75], x: i32, y: i32, z: i32| {
                let pos = room_index(x, y, z);
                defs.push(RoomDef::new(pos));
                grid[pos as usize] = Some(defs.len() - 1);
            };
        for x in 0..5 {
            for z in 0..4 {
                add(&mut defs, &mut grid, x, 0, z);
            }
        }
        for x in 0..5 {
            for z in 0..4 {
                add(&mut defs, &mut grid, x, 1, z);
            }
        }
        for x in 1..4 {
            for z in 0..2 {
                add(&mut defs, &mut grid, x, 2, z);
            }
        }
        let source = grid[room_index(2, 0, 0) as usize].expect("source room");
        for x in 0..5 {
            for z in 0..5 {
                for y in 0..3 {
                    let Some(room) = grid[room_index(x, y, z) as usize] else {
                        continue;
                    };
                    for (d, (dx, dy, dz)) in STEP.iter().enumerate() {
                        let (nx, ny, nz) = (x + dx, y + dy, z + dz);
                        if !(0..5).contains(&nx) || !(0..5).contains(&nz) || !(0..3).contains(&ny) {
                            continue;
                        }
                        if let Some(next) = grid[room_index(nx, ny, nz) as usize] {
                            // The grid's z runs against the building's.
                            let side = if nz == z { d } else { d ^ 1 };
                            connect(&mut defs, room, side, next);
                        }
                    }
                }
            }
        }
        let roof = defs.len();
        defs.push(RoomDef::new(1003));
        let left_wing = defs.len();
        defs.push(RoomDef::new(1001));
        let right_wing = defs.len();
        defs.push(RoomDef::new(1002));
        connect(
            &mut defs,
            grid[room_index(2, 2, 0) as usize].expect("top"),
            UP,
            roof,
        );
        connect(
            &mut defs,
            grid[room_index(0, 1, 0) as usize].expect("left"),
            SOUTH,
            left_wing,
        );
        connect(
            &mut defs,
            grid[room_index(4, 1, 0) as usize].expect("right"),
            SOUTH,
            right_wing,
        );
        for special in [roof, left_wing, right_wing] {
            defs[special].claimed = true;
        }
        defs[source].source = true;
        let core = grid[room_index(random.next_int_bounded(4), 0, 2) as usize].expect("core");
        let c = |defs: &Vec<RoomDef>, room: usize, d: usize| {
            defs[room].conn[d].expect("core neighbour")
        };
        let (e, n, u) = (
            c(&defs, core, EAST),
            c(&defs, core, NORTH),
            c(&defs, core, UP),
        );
        let en = c(&defs, e, NORTH);
        let (eu, nu, enu) = (c(&defs, e, UP), c(&defs, n, UP), c(&defs, en, UP));
        for room in [core, e, n, en, u, eu, nu, enu] {
            defs[room].claimed = true;
        }
        // Every grid room in grid order, then shuffled; two sides of each
        // closed where the entrance stays reachable.
        let mut order: Vec<usize> = grid.iter().flatten().copied().collect();
        for &room in &order {
            for i in 0..6 {
                defs[room].open[i] = defs[room].conn[i].is_some();
            }
        }
        for i in 0..6 {
            defs[roof].open[i] = defs[roof].conn[i].is_some();
        }
        shuffle(&mut order, random);
        let mut scan = 1;
        for &room in &order {
            let (mut closed, mut attempts) = (0, 0);
            while closed < 2 && attempts < 5 {
                attempts += 1;
                let side = random.next_int_bounded(6) as usize;
                if !defs[room].open[side] {
                    continue;
                }
                let next = defs[room].conn[side].expect("open side");
                defs[room].open[side] = false;
                defs[next].open[side ^ 1] = false;
                let a = find_source(&mut defs, room, scan);
                scan += 1;
                let reached = a && {
                    let b = find_source(&mut defs, next, scan);
                    scan += 1;
                    b
                };
                if reached {
                    closed += 1;
                } else {
                    defs[room].open[side] = true;
                    defs[next].open[side ^ 1] = true;
                }
            }
        }
        order.extend([roof, left_wing, right_wing]);

        defs[source].claimed = true;
        let mut rooms = vec![
            Room {
                kind: RoomKind::Entry,
                bbox: room_box(direction, defs[source].index, 1, 1, 1),
                def: Some(source),
            },
            Room {
                kind: RoomKind::Core,
                bbox: room_box(direction, defs[core].index, 2, 2, 2),
                def: Some(core),
            },
        ];
        for &room in &order {
            if defs[room].claimed || defs[room].index >= 75 {
                continue;
            }
            rooms.push(fit(&mut defs, room, direction, random));
        }
        let frame = Frame::new(bbox, Some(direction));
        let offset = frame.world(9, 0, 22);
        for room in &mut rooms {
            room.bbox = room.bbox.moved(offset[0], offset[1], offset[2]);
        }
        let corners = |a: [i32; 3], b: [i32; 3]| {
            BoundingBox::new(
                a[0].min(b[0]),
                a[1].min(b[1]),
                a[2].min(b[2]),
                a[0].max(b[0]),
                a[1].max(b[1]),
                a[2].max(b[2]),
            )
        };
        let left = corners(frame.world(1, 1, 1), frame.world(23, 8, 21));
        let right = corners(frame.world(34, 1, 1), frame.world(56, 8, 21));
        let penthouse = corners(frame.world(22, 13, 22), frame.world(35, 17, 35));
        let wing = random.next_int();
        rooms.push(Room {
            kind: RoomKind::Wing(wing & 1),
            bbox: left,
            def: None,
        });
        rooms.push(Room {
            kind: RoomKind::Wing(wing.wrapping_add(1) & 1),
            bbox: right,
            def: None,
        });
        rooms.push(Room {
            kind: RoomKind::Penthouse,
            bbox: penthouse,
            def: None,
        });
        Building { defs, rooms }
    }
}

/// The room fitters in order: the first that fits claims the cells.
fn fit(defs: &mut [RoomDef], room: usize, direction: Direction, random: &mut Random) -> Room {
    let open_free = |defs: &[RoomDef], r: usize, d: usize| {
        defs[r].open[d] && defs[r].conn[d].is_some_and(|n| !defs[n].claimed)
    };
    let conn = |defs: &[RoomDef], r: usize, d: usize| defs[r].conn[d].expect("connection");
    let index = defs[room].index;
    // Double XY.
    if open_free(defs, room, EAST)
        && open_free(defs, room, UP)
        && open_free(defs, conn(defs, room, EAST), UP)
    {
        let (e, u) = (conn(defs, room, EAST), conn(defs, room, UP));
        let eu = conn(defs, e, UP);
        for r in [room, e, u, eu] {
            defs[r].claimed = true;
        }
        return Room {
            kind: RoomKind::DoubleXy,
            bbox: room_box(direction, index, 2, 2, 1),
            def: Some(room),
        };
    }
    // Double YZ.
    if open_free(defs, room, NORTH)
        && open_free(defs, room, UP)
        && open_free(defs, conn(defs, room, NORTH), UP)
    {
        let (n, u) = (conn(defs, room, NORTH), conn(defs, room, UP));
        let nu = conn(defs, n, UP);
        for r in [room, n, u, nu] {
            defs[r].claimed = true;
        }
        return Room {
            kind: RoomKind::DoubleYz,
            bbox: room_box(direction, index, 1, 2, 2),
            def: Some(room),
        };
    }
    // Double Z (its fits test already holds for the room itself).
    if open_free(defs, room, NORTH) {
        let n = conn(defs, room, NORTH);
        defs[room].claimed = true;
        defs[n].claimed = true;
        return Room {
            kind: RoomKind::DoubleZ,
            bbox: room_box(direction, index, 1, 1, 2),
            def: Some(room),
        };
    }
    if open_free(defs, room, EAST) {
        let e = conn(defs, room, EAST);
        defs[room].claimed = true;
        defs[e].claimed = true;
        return Room {
            kind: RoomKind::DoubleX,
            bbox: room_box(direction, index, 2, 1, 1),
            def: Some(room),
        };
    }
    if open_free(defs, room, UP) {
        let u = conn(defs, room, UP);
        defs[room].claimed = true;
        defs[u].claimed = true;
        return Room {
            kind: RoomKind::DoubleY,
            bbox: room_box(direction, index, 1, 2, 1),
            def: Some(room),
        };
    }
    defs[room].claimed = true;
    if [WEST, EAST, NORTH, SOUTH, UP]
        .iter()
        .all(|&d| !defs[room].open[d])
    {
        return Room {
            kind: RoomKind::SimpleTop,
            bbox: room_box(direction, index, 1, 1, 1),
            def: Some(room),
        };
    }
    Room {
        kind: RoomKind::Simple(random.next_int_bounded(3)),
        bbox: room_box(direction, index, 1, 1, 1),
        def: Some(room),
    }
}

/// The blocks monuments are made of.
struct Palette {
    gray: u16,
    light: u16,
    black: u16,
    lamp: u16,
    water: u16,
    air: u16,
    wet_sponge: u16,
    gold: u16,
    /// Water, and the ice a water box keeps.
    keep: [u16; 4],
}

impl Palette {
    fn new(c: &Ctx) -> Result<Palette, String> {
        let table = c.placer.table;
        Ok(Palette {
            gray: c.state("prismarine")?,
            light: c.state("prismarine_bricks")?,
            black: c.state("dark_prismarine")?,
            lamp: c.state("sea_lantern")?,
            water: c.state("water")?,
            air: c.state("air")?,
            wet_sponge: c.state("wet_sponge")?,
            gold: c.state("gold_block")?,
            keep: [
                table.block("ice")?,
                table.block("packed_ice")?,
                table.block("blue_ice")?,
                table.block("water")?,
            ],
        })
    }
}

/// `MonumentBuilding.postProcess`: the shell, wings, entrance, roof and
/// walls, the pillars, the water around, then every room in the chunk.
pub fn post_process(piece: &mut Piece, c: &mut Ctx) -> Result<(), String> {
    let PieceKind::Monument(building) = &piece.kind else {
        return Err("not an ocean monument".into());
    };
    let building = building.clone();
    let f = &Frame::new(piece.bbox, piece.orientation);
    let p = Palette::new(c)?;
    let water_height = c.region.sea_level.max(64) - piece.bbox.min_y;
    water_box(c, f, &p, (0, 0, 0), (58, water_height, 58));
    wing(c, f, &p, false, 0);
    wing(c, f, &p, true, 33);
    entrance_archs(c, f, &p);
    entrance_wall(c, f, &p);
    roof_piece(c, f, &p);
    lower_wall(c, f, &p);
    middle_wall(c, f, &p);
    upper_wall(c, f, &p);
    for pillar_x in 0..7 {
        let mut pillar_z = 0;
        while pillar_z < 7 {
            if pillar_z == 0 && pillar_x == 3 {
                pillar_z = 6;
            }
            let (bx, bz) = (pillar_x * 9, pillar_z * 9);
            for w in 0..4 {
                for d in 0..4 {
                    c.place(f, p.light, bx + w, 0, bz + d);
                    c.fill_column_down(f, p.light, bx + w, -1, bz + d);
                }
            }
            pillar_z += if pillar_x != 0 && pillar_x != 6 { 6 } else { 1 };
        }
    }
    for i in 0..5 {
        water_box(c, f, &p, (-1 - i, i * 2, -1 - i), (-1 - i, 23, 58 + i));
        water_box(c, f, &p, (58 + i, i * 2, -1 - i), (58 + i, 23, 58 + i));
        water_box(c, f, &p, (-i, i * 2, -1 - i), (57 + i, 23, -1 - i));
        water_box(c, f, &p, (-i, i * 2, 58 + i), (57 + i, 23, 58 + i));
    }
    let direction = piece.orientation;
    for room in &building.rooms {
        if room.bbox.intersects(&c.chunk_box) {
            let rf = &Frame::new(room.bbox, direction);
            let d = room.def.map(|i| &building.defs[i]);
            place_room(c, rf, &p, room.kind, d, &building.defs)?;
        }
    }
    Ok(())
}

/// `generateWaterBox`: water below sea level and air above (where no water
/// stands yet), keeping water and ice.
fn water_box(
    c: &mut Ctx,
    f: &Frame,
    p: &Palette,
    (x0, y0, z0): (i32, i32, i32),
    (x1, y1, z1): (i32, i32, i32),
) {
    let sea_level = c.region.sea_level;
    for y in y0..=y1 {
        for x in x0..=x1 {
            for z in z0..=z1 {
                let block = c.get_block(f, x, y, z);
                if p.keep.contains(&c.placer.table.block_of(block)) {
                    continue;
                }
                if f.world_y(y) >= sea_level && block != p.water {
                    c.place(f, p.air, x, y, z);
                } else {
                    c.place(f, p.water, x, y, z);
                }
            }
        }
    }
}

/// `generateDefaultFloor`: a floor, with a hole ringed by bricks where the
/// room opens downward.
fn default_floor(c: &mut Ctx, f: &Frame, p: &Palette, x: i32, z: i32, down: bool) {
    let (gray, light) = (p.gray, p.light);
    if down {
        c.generate_box(f, (x, 0, z), (x + 2, 0, z + 7), gray, gray, false);
        c.generate_box(f, (x + 5, 0, z), (x + 7, 0, z + 7), gray, gray, false);
        c.generate_box(f, (x + 3, 0, z), (x + 4, 0, z + 2), gray, gray, false);
        c.generate_box(f, (x + 3, 0, z + 5), (x + 4, 0, z + 7), gray, gray, false);
        c.generate_box(f, (x + 3, 0, z + 2), (x + 4, 0, z + 2), light, light, false);
        c.generate_box(f, (x + 3, 0, z + 5), (x + 4, 0, z + 5), light, light, false);
        c.generate_box(f, (x + 2, 0, z + 3), (x + 2, 0, z + 4), light, light, false);
        c.generate_box(f, (x + 5, 0, z + 3), (x + 5, 0, z + 4), light, light, false);
    } else {
        c.generate_box(f, (x, 0, z), (x + 7, 0, z + 7), gray, gray, false);
    }
}

/// `generateBoxOnFillOnly`: the state wherever water stands.
fn fill_only(
    c: &mut Ctx,
    f: &Frame,
    p: &Palette,
    (x0, y0, z0): (i32, i32, i32),
    (x1, y1, z1): (i32, i32, i32),
    state: u16,
) {
    for y in y0..=y1 {
        for x in x0..=x1 {
            for z in z0..=z1 {
                if c.get_block(f, x, y, z) == p.water {
                    c.place(f, state, x, y, z);
                }
            }
        }
    }
}

/// `chunkIntersects`: whether the chunk reaches the area's columns.
fn intersects(c: &Ctx, f: &Frame, x0: i32, z0: i32, x1: i32, z1: i32) -> bool {
    let (wx0, wz0) = (f.world_x(x0, z0), f.world_z(x0, z0));
    let (wx1, wz1) = (f.world_x(x1, z1), f.world_z(x1, z1));
    c.chunk_box
        .intersects_xz(wx0.min(wx1), wz0.min(wz1), wx0.max(wx1), wz0.max(wz1))
}

/// `spawnElder`: an elder guardian, recorded with its `finalizeSpawn`.
fn spawn_elder(c: &mut Ctx, f: &Frame, x: i32, y: i32, z: i32) -> Result<(), String> {
    let pos = f.world(x, y, z);
    if !c.chunk_box.is_inside(pos[0], pos[1], pos[2]) {
        return Ok(());
    }
    c.region.add_entity(Entity {
        kind: "minecraft:elder_guardian",
        pos: [pos[0] as f64 + 0.5, pos[1] as f64, pos[2] as f64 + 0.5],
        // `new ElderGuardian` requires persistence.
        persistent: true,
        ..Entity::default()
    });
    super::mobs::finalize(c, "minecraft:elder_guardian");
    Ok(())
}

fn wing(c: &mut Ctx, f: &Frame, p: &Palette, flipped: bool, xoff: i32) {
    if intersects(c, f, xoff, 0, xoff + 23, 20) {
        c.generate_box(f, (xoff, 0, 0), (xoff + 24, 0, 20), p.gray, p.gray, false);
        water_box(c, f, p, (xoff, 1, 0), (xoff + 24, 10, 20));
        for i in 0..4 {
            c.generate_box(
                f,
                (xoff + i, i + 1, i),
                (xoff + i, i + 1, 20),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (xoff + i + 7, i + 5, i + 7),
                (xoff + i + 7, i + 5, 20),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (xoff + 17 - i, i + 5, i + 7),
                (xoff + 17 - i, i + 5, 20),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (xoff + 24 - i, i + 1, i),
                (xoff + 24 - i, i + 1, 20),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (xoff + i + 1, i + 1, i),
                (xoff + 23 - i, i + 1, i),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (xoff + i + 8, i + 5, i + 7),
                (xoff + 16 - i, i + 5, i + 7),
                p.light,
                p.light,
                false,
            );
        }
        c.generate_box(
            f,
            (xoff + 4, 4, 4),
            (xoff + 6, 4, 20),
            p.gray,
            p.gray,
            false,
        );
        c.generate_box(
            f,
            (xoff + 7, 4, 4),
            (xoff + 17, 4, 6),
            p.gray,
            p.gray,
            false,
        );
        c.generate_box(
            f,
            (xoff + 18, 4, 4),
            (xoff + 20, 4, 20),
            p.gray,
            p.gray,
            false,
        );
        c.generate_box(
            f,
            (xoff + 11, 8, 11),
            (xoff + 13, 8, 20),
            p.gray,
            p.gray,
            false,
        );
        c.place(f, p.light, xoff + 12, 9, 12);
        c.place(f, p.light, xoff + 12, 9, 15);
        c.place(f, p.light, xoff + 12, 9, 18);
        let left_pos = xoff + (if flipped { 19 } else { 5 });
        let right_pos = xoff + (if flipped { 5 } else { 19 });
        for z in (5..=20).rev().step_by(3) {
            c.place(f, p.light, left_pos, 5, z);
        }
        for z in (7..=19).rev().step_by(3) {
            c.place(f, p.light, right_pos, 5, z);
        }
        for i in 0..4 {
            let pos = if flipped {
                xoff + 24 - (17 - i * 3)
            } else {
                xoff + 17 - i * 3
            };
            c.place(f, p.light, pos, 5, 5);
        }
        c.place(f, p.light, right_pos, 5, 5);
        c.generate_box(
            f,
            (xoff + 11, 1, 12),
            (xoff + 13, 7, 12),
            p.gray,
            p.gray,
            false,
        );
        c.generate_box(
            f,
            (xoff + 12, 1, 11),
            (xoff + 12, 7, 13),
            p.gray,
            p.gray,
            false,
        );
    }
}

fn entrance_archs(c: &mut Ctx, f: &Frame, p: &Palette) {
    if intersects(c, f, 22, 5, 35, 17) {
        water_box(c, f, p, (25, 0, 0), (32, 8, 20));
        for i in 0..4 {
            c.generate_box(
                f,
                (24, 2, 5 + i * 4),
                (24, 4, 5 + i * 4),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (22, 4, 5 + i * 4),
                (23, 4, 5 + i * 4),
                p.light,
                p.light,
                false,
            );
            c.place(f, p.light, 25, 5, 5 + i * 4);
            c.place(f, p.light, 26, 6, 5 + i * 4);
            c.place(f, p.lamp, 26, 5, 5 + i * 4);
            c.generate_box(
                f,
                (33, 2, 5 + i * 4),
                (33, 4, 5 + i * 4),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (34, 4, 5 + i * 4),
                (35, 4, 5 + i * 4),
                p.light,
                p.light,
                false,
            );
            c.place(f, p.light, 32, 5, 5 + i * 4);
            c.place(f, p.light, 31, 6, 5 + i * 4);
            c.place(f, p.lamp, 31, 5, 5 + i * 4);
            c.generate_box(
                f,
                (27, 6, 5 + i * 4),
                (30, 6, 5 + i * 4),
                p.gray,
                p.gray,
                false,
            );
        }
    }
}

fn entrance_wall(c: &mut Ctx, f: &Frame, p: &Palette) {
    if intersects(c, f, 15, 20, 42, 21) {
        c.generate_box(f, (15, 0, 21), (42, 0, 21), p.gray, p.gray, false);
        water_box(c, f, p, (26, 1, 21), (31, 3, 21));
        c.generate_box(f, (21, 12, 21), (36, 12, 21), p.gray, p.gray, false);
        c.generate_box(f, (17, 11, 21), (40, 11, 21), p.gray, p.gray, false);
        c.generate_box(f, (16, 10, 21), (41, 10, 21), p.gray, p.gray, false);
        c.generate_box(f, (15, 7, 21), (42, 9, 21), p.gray, p.gray, false);
        c.generate_box(f, (16, 6, 21), (41, 6, 21), p.gray, p.gray, false);
        c.generate_box(f, (17, 5, 21), (40, 5, 21), p.gray, p.gray, false);
        c.generate_box(f, (21, 4, 21), (36, 4, 21), p.gray, p.gray, false);
        c.generate_box(f, (22, 3, 21), (26, 3, 21), p.gray, p.gray, false);
        c.generate_box(f, (31, 3, 21), (35, 3, 21), p.gray, p.gray, false);
        c.generate_box(f, (23, 2, 21), (25, 2, 21), p.gray, p.gray, false);
        c.generate_box(f, (32, 2, 21), (34, 2, 21), p.gray, p.gray, false);
        c.generate_box(f, (28, 4, 20), (29, 4, 21), p.light, p.light, false);
        c.place(f, p.light, 27, 3, 21);
        c.place(f, p.light, 30, 3, 21);
        c.place(f, p.light, 26, 2, 21);
        c.place(f, p.light, 31, 2, 21);
        c.place(f, p.light, 25, 1, 21);
        c.place(f, p.light, 32, 1, 21);
        for i in 0..7 {
            c.place(f, p.black, 28 - i, 6 + i, 21);
            c.place(f, p.black, 29 + i, 6 + i, 21);
        }
        for i in 0..4 {
            c.place(f, p.black, 28 - i, 9 + i, 21);
            c.place(f, p.black, 29 + i, 9 + i, 21);
        }
        c.place(f, p.black, 28, 12, 21);
        c.place(f, p.black, 29, 12, 21);
        for i in 0..3 {
            c.place(f, p.black, 22 - i * 2, 8, 21);
            c.place(f, p.black, 22 - i * 2, 9, 21);
            c.place(f, p.black, 35 + i * 2, 8, 21);
            c.place(f, p.black, 35 + i * 2, 9, 21);
        }
        water_box(c, f, p, (15, 13, 21), (42, 15, 21));
        water_box(c, f, p, (15, 1, 21), (15, 6, 21));
        water_box(c, f, p, (16, 1, 21), (16, 5, 21));
        water_box(c, f, p, (17, 1, 21), (20, 4, 21));
        water_box(c, f, p, (21, 1, 21), (21, 3, 21));
        water_box(c, f, p, (22, 1, 21), (22, 2, 21));
        water_box(c, f, p, (23, 1, 21), (24, 1, 21));
        water_box(c, f, p, (42, 1, 21), (42, 6, 21));
        water_box(c, f, p, (41, 1, 21), (41, 5, 21));
        water_box(c, f, p, (37, 1, 21), (40, 4, 21));
        water_box(c, f, p, (36, 1, 21), (36, 3, 21));
        water_box(c, f, p, (33, 1, 21), (34, 1, 21));
        water_box(c, f, p, (35, 1, 21), (35, 2, 21));
    }
}

fn roof_piece(c: &mut Ctx, f: &Frame, p: &Palette) {
    if intersects(c, f, 21, 21, 36, 36) {
        c.generate_box(f, (21, 0, 22), (36, 0, 36), p.gray, p.gray, false);
        water_box(c, f, p, (21, 1, 22), (36, 23, 36));
        for i in 0..4 {
            c.generate_box(
                f,
                (21 + i, 13 + i, 21 + i),
                (36 - i, 13 + i, 21 + i),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (21 + i, 13 + i, 36 - i),
                (36 - i, 13 + i, 36 - i),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (21 + i, 13 + i, 22 + i),
                (21 + i, 13 + i, 35 - i),
                p.light,
                p.light,
                false,
            );
            c.generate_box(
                f,
                (36 - i, 13 + i, 22 + i),
                (36 - i, 13 + i, 35 - i),
                p.light,
                p.light,
                false,
            );
        }
        c.generate_box(f, (25, 16, 25), (32, 16, 32), p.gray, p.gray, false);
        c.generate_box(f, (25, 17, 25), (25, 19, 25), p.light, p.light, false);
        c.generate_box(f, (32, 17, 25), (32, 19, 25), p.light, p.light, false);
        c.generate_box(f, (25, 17, 32), (25, 19, 32), p.light, p.light, false);
        c.generate_box(f, (32, 17, 32), (32, 19, 32), p.light, p.light, false);
        c.place(f, p.light, 26, 20, 26);
        c.place(f, p.light, 27, 21, 27);
        c.place(f, p.lamp, 27, 20, 27);
        c.place(f, p.light, 26, 20, 31);
        c.place(f, p.light, 27, 21, 30);
        c.place(f, p.lamp, 27, 20, 30);
        c.place(f, p.light, 31, 20, 31);
        c.place(f, p.light, 30, 21, 30);
        c.place(f, p.lamp, 30, 20, 30);
        c.place(f, p.light, 31, 20, 26);
        c.place(f, p.light, 30, 21, 27);
        c.place(f, p.lamp, 30, 20, 27);
        c.generate_box(f, (28, 21, 27), (29, 21, 27), p.gray, p.gray, false);
        c.generate_box(f, (27, 21, 28), (27, 21, 29), p.gray, p.gray, false);
        c.generate_box(f, (28, 21, 30), (29, 21, 30), p.gray, p.gray, false);
        c.generate_box(f, (30, 21, 28), (30, 21, 29), p.gray, p.gray, false);
    }
}

fn lower_wall(c: &mut Ctx, f: &Frame, p: &Palette) {
    if intersects(c, f, 0, 21, 6, 58) {
        c.generate_box(f, (0, 0, 21), (6, 0, 57), p.gray, p.gray, false);
        water_box(c, f, p, (0, 1, 21), (6, 7, 57));
        c.generate_box(f, (4, 4, 21), (6, 4, 53), p.gray, p.gray, false);
        for i in 0..4 {
            c.generate_box(
                f,
                (i, i + 1, 21),
                (i, i + 1, 57 - i),
                p.light,
                p.light,
                false,
            );
        }
        for z in (23..53).step_by(3) {
            c.place(f, p.light, 5, 5, z);
        }
        c.place(f, p.light, 5, 5, 52);
        for i in 0..4 {
            c.generate_box(
                f,
                (i, i + 1, 21),
                (i, i + 1, 57 - i),
                p.light,
                p.light,
                false,
            );
        }
        c.generate_box(f, (4, 1, 52), (6, 3, 52), p.gray, p.gray, false);
        c.generate_box(f, (5, 1, 51), (5, 3, 53), p.gray, p.gray, false);
    }
    if intersects(c, f, 51, 21, 58, 58) {
        c.generate_box(f, (51, 0, 21), (57, 0, 57), p.gray, p.gray, false);
        water_box(c, f, p, (51, 1, 21), (57, 7, 57));
        c.generate_box(f, (51, 4, 21), (53, 4, 53), p.gray, p.gray, false);
        for i in 0..4 {
            c.generate_box(
                f,
                (57 - i, i + 1, 21),
                (57 - i, i + 1, 57 - i),
                p.light,
                p.light,
                false,
            );
        }
        for z in (23..53).step_by(3) {
            c.place(f, p.light, 52, 5, z);
        }
        c.place(f, p.light, 52, 5, 52);
        c.generate_box(f, (51, 1, 52), (53, 3, 52), p.gray, p.gray, false);
        c.generate_box(f, (52, 1, 51), (52, 3, 53), p.gray, p.gray, false);
    }
    if intersects(c, f, 0, 51, 57, 57) {
        c.generate_box(f, (7, 0, 51), (50, 0, 57), p.gray, p.gray, false);
        water_box(c, f, p, (7, 1, 51), (50, 10, 57));
        for i in 0..4 {
            c.generate_box(
                f,
                (i + 1, i + 1, 57 - i),
                (56 - i, i + 1, 57 - i),
                p.light,
                p.light,
                false,
            );
        }
    }
}

fn middle_wall(c: &mut Ctx, f: &Frame, p: &Palette) {
    if intersects(c, f, 7, 21, 13, 50) {
        c.generate_box(f, (7, 0, 21), (13, 0, 50), p.gray, p.gray, false);
        water_box(c, f, p, (7, 1, 21), (13, 10, 50));
        c.generate_box(f, (11, 8, 21), (13, 8, 53), p.gray, p.gray, false);
        for i in 0..4 {
            c.generate_box(
                f,
                (i + 7, i + 5, 21),
                (i + 7, i + 5, 54),
                p.light,
                p.light,
                false,
            );
        }
        for z in (21..=45).step_by(3) {
            c.place(f, p.light, 12, 9, z);
        }
    }
    if intersects(c, f, 44, 21, 50, 54) {
        c.generate_box(f, (44, 0, 21), (50, 0, 50), p.gray, p.gray, false);
        water_box(c, f, p, (44, 1, 21), (50, 10, 50));
        c.generate_box(f, (44, 8, 21), (46, 8, 53), p.gray, p.gray, false);
        for i in 0..4 {
            c.generate_box(
                f,
                (50 - i, i + 5, 21),
                (50 - i, i + 5, 54),
                p.light,
                p.light,
                false,
            );
        }
        for z in (21..=45).step_by(3) {
            c.place(f, p.light, 45, 9, z);
        }
    }
    if intersects(c, f, 8, 44, 49, 54) {
        c.generate_box(f, (14, 0, 44), (43, 0, 50), p.gray, p.gray, false);
        water_box(c, f, p, (14, 1, 44), (43, 10, 50));
        for x in (12..=45).step_by(3) {
            c.place(f, p.light, x, 9, 45);
            c.place(f, p.light, x, 9, 52);
            if x == 12 || x == 18 || x == 24 || x == 33 || x == 39 || x == 45 {
                c.place(f, p.light, x, 9, 47);
                c.place(f, p.light, x, 9, 50);
                c.place(f, p.light, x, 10, 45);
                c.place(f, p.light, x, 10, 46);
                c.place(f, p.light, x, 10, 51);
                c.place(f, p.light, x, 10, 52);
                c.place(f, p.light, x, 11, 47);
                c.place(f, p.light, x, 11, 50);
                c.place(f, p.light, x, 12, 48);
                c.place(f, p.light, x, 12, 49);
            }
        }
        for i in 0..3 {
            c.generate_box(
                f,
                (8 + i, 5 + i, 54),
                (49 - i, 5 + i, 54),
                p.gray,
                p.gray,
                false,
            );
        }
        c.generate_box(f, (11, 8, 54), (46, 8, 54), p.light, p.light, false);
        c.generate_box(f, (14, 8, 44), (43, 8, 53), p.gray, p.gray, false);
    }
}

fn upper_wall(c: &mut Ctx, f: &Frame, p: &Palette) {
    if intersects(c, f, 14, 21, 20, 43) {
        c.generate_box(f, (14, 0, 21), (20, 0, 43), p.gray, p.gray, false);
        water_box(c, f, p, (14, 1, 22), (20, 14, 43));
        c.generate_box(f, (18, 12, 22), (20, 12, 39), p.gray, p.gray, false);
        c.generate_box(f, (18, 12, 21), (20, 12, 21), p.light, p.light, false);
        for i in 0..4 {
            c.generate_box(
                f,
                (i + 14, i + 9, 21),
                (i + 14, i + 9, 43 - i),
                p.light,
                p.light,
                false,
            );
        }
        for z in (23..=39).step_by(3) {
            c.place(f, p.light, 19, 13, z);
        }
    }
    if intersects(c, f, 37, 21, 43, 43) {
        c.generate_box(f, (37, 0, 21), (43, 0, 43), p.gray, p.gray, false);
        water_box(c, f, p, (37, 1, 22), (43, 14, 43));
        c.generate_box(f, (37, 12, 22), (39, 12, 39), p.gray, p.gray, false);
        c.generate_box(f, (37, 12, 21), (39, 12, 21), p.light, p.light, false);
        for i in 0..4 {
            c.generate_box(
                f,
                (43 - i, i + 9, 21),
                (43 - i, i + 9, 43 - i),
                p.light,
                p.light,
                false,
            );
        }
        for z in (23..=39).step_by(3) {
            c.place(f, p.light, 38, 13, z);
        }
    }
    if intersects(c, f, 15, 37, 42, 43) {
        c.generate_box(f, (21, 0, 37), (36, 0, 43), p.gray, p.gray, false);
        water_box(c, f, p, (21, 1, 37), (36, 14, 43));
        c.generate_box(f, (21, 12, 37), (36, 12, 39), p.gray, p.gray, false);
        for i in 0..4 {
            c.generate_box(
                f,
                (15 + i, i + 9, 43 - i),
                (42 - i, i + 9, 43 - i),
                p.light,
                p.light,
                false,
            );
        }
        for x in (21..=36).step_by(3) {
            c.place(f, p.light, x, 13, 38);
        }
    }
}

/// A room's `postProcess`, in its own frame.
fn place_room(
    c: &mut Ctx,
    f: &Frame,
    p: &Palette,
    kind: RoomKind,
    def: Option<&RoomDef>,
    defs: &[RoomDef],
) -> Result<(), String> {
    let d = def.unwrap_or(&defs[0]);
    match kind {
        RoomKind::Entry => {
            c.generate_box(f, (0, 3, 0), (2, 3, 7), p.light, p.light, false);
            c.generate_box(f, (5, 3, 0), (7, 3, 7), p.light, p.light, false);
            c.generate_box(f, (0, 2, 0), (1, 2, 7), p.light, p.light, false);
            c.generate_box(f, (6, 2, 0), (7, 2, 7), p.light, p.light, false);
            c.generate_box(f, (0, 1, 0), (0, 1, 7), p.light, p.light, false);
            c.generate_box(f, (7, 1, 0), (7, 1, 7), p.light, p.light, false);
            c.generate_box(f, (0, 1, 7), (7, 3, 7), p.light, p.light, false);
            c.generate_box(f, (1, 1, 0), (2, 3, 0), p.light, p.light, false);
            c.generate_box(f, (5, 1, 0), (6, 3, 0), p.light, p.light, false);
            if d.open[NORTH] {
                water_box(c, f, p, (3, 1, 7), (4, 2, 7));
            }
            if d.open[WEST] {
                water_box(c, f, p, (0, 1, 3), (1, 2, 4));
            }
            if d.open[EAST] {
                water_box(c, f, p, (6, 1, 3), (7, 2, 4));
            }
        }
        RoomKind::Core => {
            fill_only(c, f, p, (1, 8, 0), (14, 8, 14), p.gray);
            let mut block = p.light;
            c.generate_box(f, (0, 7, 0), (0, 7, 15), block, block, false);
            c.generate_box(f, (15, 7, 0), (15, 7, 15), block, block, false);
            c.generate_box(f, (1, 7, 0), (15, 7, 0), block, block, false);
            c.generate_box(f, (1, 7, 15), (14, 7, 15), block, block, false);
            for yx in 1..=6 {
                block = p.light;
                if yx == 2 || yx == 6 {
                    block = p.gray;
                }
                for x in (0..=15).step_by(15) {
                    c.generate_box(f, (x, yx, 0), (x, yx, 1), block, block, false);
                    c.generate_box(f, (x, yx, 6), (x, yx, 9), block, block, false);
                    c.generate_box(f, (x, yx, 14), (x, yx, 15), block, block, false);
                }
                c.generate_box(f, (1, yx, 0), (1, yx, 0), block, block, false);
                c.generate_box(f, (6, yx, 0), (9, yx, 0), block, block, false);
                c.generate_box(f, (14, yx, 0), (14, yx, 0), block, block, false);
                c.generate_box(f, (1, yx, 15), (14, yx, 15), block, block, false);
            }
            c.generate_box(f, (6, 3, 6), (9, 6, 9), p.black, p.black, false);
            c.generate_box(f, (7, 4, 7), (8, 5, 8), p.gold, p.gold, false);
            for yx in (3..=6).step_by(3) {
                for x in (6..=9).step_by(3) {
                    c.place(f, p.lamp, x, yx, 6);
                    c.place(f, p.lamp, x, yx, 9);
                }
            }
            c.generate_box(f, (5, 1, 6), (5, 2, 6), p.light, p.light, false);
            c.generate_box(f, (5, 1, 9), (5, 2, 9), p.light, p.light, false);
            c.generate_box(f, (10, 1, 6), (10, 2, 6), p.light, p.light, false);
            c.generate_box(f, (10, 1, 9), (10, 2, 9), p.light, p.light, false);
            c.generate_box(f, (6, 1, 5), (6, 2, 5), p.light, p.light, false);
            c.generate_box(f, (9, 1, 5), (9, 2, 5), p.light, p.light, false);
            c.generate_box(f, (6, 1, 10), (6, 2, 10), p.light, p.light, false);
            c.generate_box(f, (9, 1, 10), (9, 2, 10), p.light, p.light, false);
            c.generate_box(f, (5, 2, 5), (5, 6, 5), p.light, p.light, false);
            c.generate_box(f, (5, 2, 10), (5, 6, 10), p.light, p.light, false);
            c.generate_box(f, (10, 2, 5), (10, 6, 5), p.light, p.light, false);
            c.generate_box(f, (10, 2, 10), (10, 6, 10), p.light, p.light, false);
            c.generate_box(f, (5, 7, 1), (5, 7, 6), p.light, p.light, false);
            c.generate_box(f, (10, 7, 1), (10, 7, 6), p.light, p.light, false);
            c.generate_box(f, (5, 7, 9), (5, 7, 14), p.light, p.light, false);
            c.generate_box(f, (10, 7, 9), (10, 7, 14), p.light, p.light, false);
            c.generate_box(f, (1, 7, 5), (6, 7, 5), p.light, p.light, false);
            c.generate_box(f, (1, 7, 10), (6, 7, 10), p.light, p.light, false);
            c.generate_box(f, (9, 7, 5), (14, 7, 5), p.light, p.light, false);
            c.generate_box(f, (9, 7, 10), (14, 7, 10), p.light, p.light, false);
            c.generate_box(f, (2, 1, 2), (2, 1, 3), p.light, p.light, false);
            c.generate_box(f, (3, 1, 2), (3, 1, 2), p.light, p.light, false);
            c.generate_box(f, (13, 1, 2), (13, 1, 3), p.light, p.light, false);
            c.generate_box(f, (12, 1, 2), (12, 1, 2), p.light, p.light, false);
            c.generate_box(f, (2, 1, 12), (2, 1, 13), p.light, p.light, false);
            c.generate_box(f, (3, 1, 13), (3, 1, 13), p.light, p.light, false);
            c.generate_box(f, (13, 1, 12), (13, 1, 13), p.light, p.light, false);
            c.generate_box(f, (12, 1, 13), (12, 1, 13), p.light, p.light, false);
        }
        RoomKind::DoubleX => {
            let east = &defs[d.conn[EAST].unwrap()];
            let west = d;
            if d.index / 25 > 0 {
                default_floor(c, f, p, 8, 0, east.open[DOWN]);
                default_floor(c, f, p, 0, 0, west.open[DOWN]);
            }
            if west.conn[UP].is_none() {
                fill_only(c, f, p, (1, 4, 1), (7, 4, 6), p.gray);
            }
            if east.conn[UP].is_none() {
                fill_only(c, f, p, (8, 4, 1), (14, 4, 6), p.gray);
            }
            c.generate_box(f, (0, 3, 0), (0, 3, 7), p.light, p.light, false);
            c.generate_box(f, (15, 3, 0), (15, 3, 7), p.light, p.light, false);
            c.generate_box(f, (1, 3, 0), (15, 3, 0), p.light, p.light, false);
            c.generate_box(f, (1, 3, 7), (14, 3, 7), p.light, p.light, false);
            c.generate_box(f, (0, 2, 0), (0, 2, 7), p.gray, p.gray, false);
            c.generate_box(f, (15, 2, 0), (15, 2, 7), p.gray, p.gray, false);
            c.generate_box(f, (1, 2, 0), (15, 2, 0), p.gray, p.gray, false);
            c.generate_box(f, (1, 2, 7), (14, 2, 7), p.gray, p.gray, false);
            c.generate_box(f, (0, 1, 0), (0, 1, 7), p.light, p.light, false);
            c.generate_box(f, (15, 1, 0), (15, 1, 7), p.light, p.light, false);
            c.generate_box(f, (1, 1, 0), (15, 1, 0), p.light, p.light, false);
            c.generate_box(f, (1, 1, 7), (14, 1, 7), p.light, p.light, false);
            c.generate_box(f, (5, 1, 0), (10, 1, 4), p.light, p.light, false);
            c.generate_box(f, (6, 2, 0), (9, 2, 3), p.gray, p.gray, false);
            c.generate_box(f, (5, 3, 0), (10, 3, 4), p.light, p.light, false);
            c.place(f, p.lamp, 6, 2, 3);
            c.place(f, p.lamp, 9, 2, 3);
            if west.open[SOUTH] {
                water_box(c, f, p, (3, 1, 0), (4, 2, 0));
            }
            if west.open[NORTH] {
                water_box(c, f, p, (3, 1, 7), (4, 2, 7));
            }
            if west.open[WEST] {
                water_box(c, f, p, (0, 1, 3), (0, 2, 4));
            }
            if east.open[SOUTH] {
                water_box(c, f, p, (11, 1, 0), (12, 2, 0));
            }
            if east.open[NORTH] {
                water_box(c, f, p, (11, 1, 7), (12, 2, 7));
            }
            if east.open[EAST] {
                water_box(c, f, p, (15, 1, 3), (15, 2, 4));
            }
        }
        RoomKind::DoubleXy => {
            let east = &defs[d.conn[EAST].unwrap()];
            let west = d;
            let west_up = &defs[west.conn[UP].unwrap()];
            let east_up = &defs[east.conn[UP].unwrap()];
            if d.index / 25 > 0 {
                default_floor(c, f, p, 8, 0, east.open[DOWN]);
                default_floor(c, f, p, 0, 0, west.open[DOWN]);
            }
            if west_up.conn[UP].is_none() {
                fill_only(c, f, p, (1, 8, 1), (7, 8, 6), p.gray);
            }
            if east_up.conn[UP].is_none() {
                fill_only(c, f, p, (8, 8, 1), (14, 8, 6), p.gray);
            }
            for y in 1..=7 {
                let mut block = p.light;
                if y == 2 || y == 6 {
                    block = p.gray;
                }
                c.generate_box(f, (0, y, 0), (0, y, 7), block, block, false);
                c.generate_box(f, (15, y, 0), (15, y, 7), block, block, false);
                c.generate_box(f, (1, y, 0), (15, y, 0), block, block, false);
                c.generate_box(f, (1, y, 7), (14, y, 7), block, block, false);
            }
            c.generate_box(f, (2, 1, 3), (2, 7, 4), p.light, p.light, false);
            c.generate_box(f, (3, 1, 2), (4, 7, 2), p.light, p.light, false);
            c.generate_box(f, (3, 1, 5), (4, 7, 5), p.light, p.light, false);
            c.generate_box(f, (13, 1, 3), (13, 7, 4), p.light, p.light, false);
            c.generate_box(f, (11, 1, 2), (12, 7, 2), p.light, p.light, false);
            c.generate_box(f, (11, 1, 5), (12, 7, 5), p.light, p.light, false);
            c.generate_box(f, (5, 1, 3), (5, 3, 4), p.light, p.light, false);
            c.generate_box(f, (10, 1, 3), (10, 3, 4), p.light, p.light, false);
            c.generate_box(f, (5, 7, 2), (10, 7, 5), p.light, p.light, false);
            c.generate_box(f, (5, 5, 2), (5, 7, 2), p.light, p.light, false);
            c.generate_box(f, (10, 5, 2), (10, 7, 2), p.light, p.light, false);
            c.generate_box(f, (5, 5, 5), (5, 7, 5), p.light, p.light, false);
            c.generate_box(f, (10, 5, 5), (10, 7, 5), p.light, p.light, false);
            c.place(f, p.light, 6, 6, 2);
            c.place(f, p.light, 9, 6, 2);
            c.place(f, p.light, 6, 6, 5);
            c.place(f, p.light, 9, 6, 5);
            c.generate_box(f, (5, 4, 3), (6, 4, 4), p.light, p.light, false);
            c.generate_box(f, (9, 4, 3), (10, 4, 4), p.light, p.light, false);
            c.place(f, p.lamp, 5, 4, 2);
            c.place(f, p.lamp, 5, 4, 5);
            c.place(f, p.lamp, 10, 4, 2);
            c.place(f, p.lamp, 10, 4, 5);
            if west.open[SOUTH] {
                water_box(c, f, p, (3, 1, 0), (4, 2, 0));
            }
            if west.open[NORTH] {
                water_box(c, f, p, (3, 1, 7), (4, 2, 7));
            }
            if west.open[WEST] {
                water_box(c, f, p, (0, 1, 3), (0, 2, 4));
            }
            if east.open[SOUTH] {
                water_box(c, f, p, (11, 1, 0), (12, 2, 0));
            }
            if east.open[NORTH] {
                water_box(c, f, p, (11, 1, 7), (12, 2, 7));
            }
            if east.open[EAST] {
                water_box(c, f, p, (15, 1, 3), (15, 2, 4));
            }
            if west_up.open[SOUTH] {
                water_box(c, f, p, (3, 5, 0), (4, 6, 0));
            }
            if west_up.open[NORTH] {
                water_box(c, f, p, (3, 5, 7), (4, 6, 7));
            }
            if west_up.open[WEST] {
                water_box(c, f, p, (0, 5, 3), (0, 6, 4));
            }
            if east_up.open[SOUTH] {
                water_box(c, f, p, (11, 5, 0), (12, 6, 0));
            }
            if east_up.open[NORTH] {
                water_box(c, f, p, (11, 5, 7), (12, 6, 7));
            }
            if east_up.open[EAST] {
                water_box(c, f, p, (15, 5, 3), (15, 6, 4));
            }
        }
        RoomKind::DoubleY => {
            if d.index / 25 > 0 {
                default_floor(c, f, p, 0, 0, d.open[DOWN]);
            }
            let above = &defs[d.conn[UP].unwrap()];
            if above.conn[UP].is_none() {
                fill_only(c, f, p, (1, 8, 1), (6, 8, 6), p.gray);
            }
            c.generate_box(f, (0, 4, 0), (0, 4, 7), p.light, p.light, false);
            c.generate_box(f, (7, 4, 0), (7, 4, 7), p.light, p.light, false);
            c.generate_box(f, (1, 4, 0), (6, 4, 0), p.light, p.light, false);
            c.generate_box(f, (1, 4, 7), (6, 4, 7), p.light, p.light, false);
            c.generate_box(f, (2, 4, 1), (2, 4, 2), p.light, p.light, false);
            c.generate_box(f, (1, 4, 2), (1, 4, 2), p.light, p.light, false);
            c.generate_box(f, (5, 4, 1), (5, 4, 2), p.light, p.light, false);
            c.generate_box(f, (6, 4, 2), (6, 4, 2), p.light, p.light, false);
            c.generate_box(f, (2, 4, 5), (2, 4, 6), p.light, p.light, false);
            c.generate_box(f, (1, 4, 5), (1, 4, 5), p.light, p.light, false);
            c.generate_box(f, (5, 4, 5), (5, 4, 6), p.light, p.light, false);
            c.generate_box(f, (6, 4, 5), (6, 4, 5), p.light, p.light, false);
            let mut definition = d;
            for y in (1..=5).step_by(4) {
                let z = 0;
                if definition.open[SOUTH] {
                    c.generate_box(f, (2, y, z), (2, y + 2, z), p.light, p.light, false);
                    c.generate_box(f, (5, y, z), (5, y + 2, z), p.light, p.light, false);
                    c.generate_box(f, (3, y + 2, z), (4, y + 2, z), p.light, p.light, false);
                } else {
                    c.generate_box(f, (0, y, z), (7, y + 2, z), p.light, p.light, false);
                    c.generate_box(f, (0, y + 1, z), (7, y + 1, z), p.gray, p.gray, false);
                }
                let var13 = 7;
                if definition.open[NORTH] {
                    c.generate_box(f, (2, y, var13), (2, y + 2, var13), p.light, p.light, false);
                    c.generate_box(f, (5, y, var13), (5, y + 2, var13), p.light, p.light, false);
                    c.generate_box(
                        f,
                        (3, y + 2, var13),
                        (4, y + 2, var13),
                        p.light,
                        p.light,
                        false,
                    );
                } else {
                    c.generate_box(f, (0, y, var13), (7, y + 2, var13), p.light, p.light, false);
                    c.generate_box(
                        f,
                        (0, y + 1, var13),
                        (7, y + 1, var13),
                        p.gray,
                        p.gray,
                        false,
                    );
                }
                let x = 0;
                if definition.open[WEST] {
                    c.generate_box(f, (x, y, 2), (x, y + 2, 2), p.light, p.light, false);
                    c.generate_box(f, (x, y, 5), (x, y + 2, 5), p.light, p.light, false);
                    c.generate_box(f, (x, y + 2, 3), (x, y + 2, 4), p.light, p.light, false);
                } else {
                    c.generate_box(f, (x, y, 0), (x, y + 2, 7), p.light, p.light, false);
                    c.generate_box(f, (x, y + 1, 0), (x, y + 1, 7), p.gray, p.gray, false);
                }
                let x2 = 7;
                if definition.open[EAST] {
                    c.generate_box(f, (x2, y, 2), (x2, y + 2, 2), p.light, p.light, false);
                    c.generate_box(f, (x2, y, 5), (x2, y + 2, 5), p.light, p.light, false);
                    c.generate_box(f, (x2, y + 2, 3), (x2, y + 2, 4), p.light, p.light, false);
                } else {
                    c.generate_box(f, (x2, y, 0), (x2, y + 2, 7), p.light, p.light, false);
                    c.generate_box(f, (x2, y + 1, 0), (x2, y + 1, 7), p.gray, p.gray, false);
                }
                definition = above;
            }
        }
        RoomKind::DoubleYz => {
            let north = &defs[d.conn[NORTH].unwrap()];
            let south = d;
            let north_up = &defs[north.conn[UP].unwrap()];
            let south_up = &defs[south.conn[UP].unwrap()];
            if d.index / 25 > 0 {
                default_floor(c, f, p, 0, 8, north.open[DOWN]);
                default_floor(c, f, p, 0, 0, south.open[DOWN]);
            }
            if south_up.conn[UP].is_none() {
                fill_only(c, f, p, (1, 8, 1), (6, 8, 7), p.gray);
            }
            if north_up.conn[UP].is_none() {
                fill_only(c, f, p, (1, 8, 8), (6, 8, 14), p.gray);
            }
            for y in 1..=7 {
                let mut block = p.light;
                if y == 2 || y == 6 {
                    block = p.gray;
                }
                c.generate_box(f, (0, y, 0), (0, y, 15), block, block, false);
                c.generate_box(f, (7, y, 0), (7, y, 15), block, block, false);
                c.generate_box(f, (1, y, 0), (6, y, 0), block, block, false);
                c.generate_box(f, (1, y, 15), (6, y, 15), block, block, false);
            }
            for y in 1..=7 {
                let mut block = p.black;
                if y == 2 || y == 6 {
                    block = p.lamp;
                }
                c.generate_box(f, (3, y, 7), (4, y, 8), block, block, false);
            }
            if south.open[SOUTH] {
                water_box(c, f, p, (3, 1, 0), (4, 2, 0));
            }
            if south.open[EAST] {
                water_box(c, f, p, (7, 1, 3), (7, 2, 4));
            }
            if south.open[WEST] {
                water_box(c, f, p, (0, 1, 3), (0, 2, 4));
            }
            if north.open[NORTH] {
                water_box(c, f, p, (3, 1, 15), (4, 2, 15));
            }
            if north.open[WEST] {
                water_box(c, f, p, (0, 1, 11), (0, 2, 12));
            }
            if north.open[EAST] {
                water_box(c, f, p, (7, 1, 11), (7, 2, 12));
            }
            if south_up.open[SOUTH] {
                water_box(c, f, p, (3, 5, 0), (4, 6, 0));
            }
            if south_up.open[EAST] {
                water_box(c, f, p, (7, 5, 3), (7, 6, 4));
                c.generate_box(f, (5, 4, 2), (6, 4, 5), p.light, p.light, false);
                c.generate_box(f, (6, 1, 2), (6, 3, 2), p.light, p.light, false);
                c.generate_box(f, (6, 1, 5), (6, 3, 5), p.light, p.light, false);
            }
            if south_up.open[WEST] {
                water_box(c, f, p, (0, 5, 3), (0, 6, 4));
                c.generate_box(f, (1, 4, 2), (2, 4, 5), p.light, p.light, false);
                c.generate_box(f, (1, 1, 2), (1, 3, 2), p.light, p.light, false);
                c.generate_box(f, (1, 1, 5), (1, 3, 5), p.light, p.light, false);
            }
            if north_up.open[NORTH] {
                water_box(c, f, p, (3, 5, 15), (4, 6, 15));
            }
            if north_up.open[WEST] {
                water_box(c, f, p, (0, 5, 11), (0, 6, 12));
                c.generate_box(f, (1, 4, 10), (2, 4, 13), p.light, p.light, false);
                c.generate_box(f, (1, 1, 10), (1, 3, 10), p.light, p.light, false);
                c.generate_box(f, (1, 1, 13), (1, 3, 13), p.light, p.light, false);
            }
            if north_up.open[EAST] {
                water_box(c, f, p, (7, 5, 11), (7, 6, 12));
                c.generate_box(f, (5, 4, 10), (6, 4, 13), p.light, p.light, false);
                c.generate_box(f, (6, 1, 10), (6, 3, 10), p.light, p.light, false);
                c.generate_box(f, (6, 1, 13), (6, 3, 13), p.light, p.light, false);
            }
        }
        RoomKind::DoubleZ => {
            let north = &defs[d.conn[NORTH].unwrap()];
            let south = d;
            if d.index / 25 > 0 {
                default_floor(c, f, p, 0, 8, north.open[DOWN]);
                default_floor(c, f, p, 0, 0, south.open[DOWN]);
            }
            if south.conn[UP].is_none() {
                fill_only(c, f, p, (1, 4, 1), (6, 4, 7), p.gray);
            }
            if north.conn[UP].is_none() {
                fill_only(c, f, p, (1, 4, 8), (6, 4, 14), p.gray);
            }
            c.generate_box(f, (0, 3, 0), (0, 3, 15), p.light, p.light, false);
            c.generate_box(f, (7, 3, 0), (7, 3, 15), p.light, p.light, false);
            c.generate_box(f, (1, 3, 0), (7, 3, 0), p.light, p.light, false);
            c.generate_box(f, (1, 3, 15), (6, 3, 15), p.light, p.light, false);
            c.generate_box(f, (0, 2, 0), (0, 2, 15), p.gray, p.gray, false);
            c.generate_box(f, (7, 2, 0), (7, 2, 15), p.gray, p.gray, false);
            c.generate_box(f, (1, 2, 0), (7, 2, 0), p.gray, p.gray, false);
            c.generate_box(f, (1, 2, 15), (6, 2, 15), p.gray, p.gray, false);
            c.generate_box(f, (0, 1, 0), (0, 1, 15), p.light, p.light, false);
            c.generate_box(f, (7, 1, 0), (7, 1, 15), p.light, p.light, false);
            c.generate_box(f, (1, 1, 0), (7, 1, 0), p.light, p.light, false);
            c.generate_box(f, (1, 1, 15), (6, 1, 15), p.light, p.light, false);
            c.generate_box(f, (1, 1, 1), (1, 1, 2), p.light, p.light, false);
            c.generate_box(f, (6, 1, 1), (6, 1, 2), p.light, p.light, false);
            c.generate_box(f, (1, 3, 1), (1, 3, 2), p.light, p.light, false);
            c.generate_box(f, (6, 3, 1), (6, 3, 2), p.light, p.light, false);
            c.generate_box(f, (1, 1, 13), (1, 1, 14), p.light, p.light, false);
            c.generate_box(f, (6, 1, 13), (6, 1, 14), p.light, p.light, false);
            c.generate_box(f, (1, 3, 13), (1, 3, 14), p.light, p.light, false);
            c.generate_box(f, (6, 3, 13), (6, 3, 14), p.light, p.light, false);
            c.generate_box(f, (2, 1, 6), (2, 3, 6), p.light, p.light, false);
            c.generate_box(f, (5, 1, 6), (5, 3, 6), p.light, p.light, false);
            c.generate_box(f, (2, 1, 9), (2, 3, 9), p.light, p.light, false);
            c.generate_box(f, (5, 1, 9), (5, 3, 9), p.light, p.light, false);
            c.generate_box(f, (3, 2, 6), (4, 2, 6), p.light, p.light, false);
            c.generate_box(f, (3, 2, 9), (4, 2, 9), p.light, p.light, false);
            c.generate_box(f, (2, 2, 7), (2, 2, 8), p.light, p.light, false);
            c.generate_box(f, (5, 2, 7), (5, 2, 8), p.light, p.light, false);
            c.place(f, p.lamp, 2, 2, 5);
            c.place(f, p.lamp, 5, 2, 5);
            c.place(f, p.lamp, 2, 2, 10);
            c.place(f, p.lamp, 5, 2, 10);
            c.place(f, p.light, 2, 3, 5);
            c.place(f, p.light, 5, 3, 5);
            c.place(f, p.light, 2, 3, 10);
            c.place(f, p.light, 5, 3, 10);
            if south.open[SOUTH] {
                water_box(c, f, p, (3, 1, 0), (4, 2, 0));
            }
            if south.open[EAST] {
                water_box(c, f, p, (7, 1, 3), (7, 2, 4));
            }
            if south.open[WEST] {
                water_box(c, f, p, (0, 1, 3), (0, 2, 4));
            }
            if north.open[NORTH] {
                water_box(c, f, p, (3, 1, 15), (4, 2, 15));
            }
            if north.open[WEST] {
                water_box(c, f, p, (0, 1, 11), (0, 2, 12));
            }
            if north.open[EAST] {
                water_box(c, f, p, (7, 1, 11), (7, 2, 12));
            }
        }
        RoomKind::Simple(design) => {
            if d.index / 25 > 0 {
                default_floor(c, f, p, 0, 0, d.open[DOWN]);
            }
            if d.conn[UP].is_none() {
                fill_only(c, f, p, (1, 4, 1), (6, 4, 6), p.gray);
            }
            let center_pillar = design != 0
                && c.random.next_bool()
                && !d.open[DOWN]
                && !d.open[UP]
                && d.count_openings() > 1;
            if design == 0 {
                c.generate_box(f, (0, 1, 0), (2, 1, 2), p.light, p.light, false);
                c.generate_box(f, (0, 3, 0), (2, 3, 2), p.light, p.light, false);
                c.generate_box(f, (0, 2, 0), (0, 2, 2), p.gray, p.gray, false);
                c.generate_box(f, (1, 2, 0), (2, 2, 0), p.gray, p.gray, false);
                c.place(f, p.lamp, 1, 2, 1);
                c.generate_box(f, (5, 1, 0), (7, 1, 2), p.light, p.light, false);
                c.generate_box(f, (5, 3, 0), (7, 3, 2), p.light, p.light, false);
                c.generate_box(f, (7, 2, 0), (7, 2, 2), p.gray, p.gray, false);
                c.generate_box(f, (5, 2, 0), (6, 2, 0), p.gray, p.gray, false);
                c.place(f, p.lamp, 6, 2, 1);
                c.generate_box(f, (0, 1, 5), (2, 1, 7), p.light, p.light, false);
                c.generate_box(f, (0, 3, 5), (2, 3, 7), p.light, p.light, false);
                c.generate_box(f, (0, 2, 5), (0, 2, 7), p.gray, p.gray, false);
                c.generate_box(f, (1, 2, 7), (2, 2, 7), p.gray, p.gray, false);
                c.place(f, p.lamp, 1, 2, 6);
                c.generate_box(f, (5, 1, 5), (7, 1, 7), p.light, p.light, false);
                c.generate_box(f, (5, 3, 5), (7, 3, 7), p.light, p.light, false);
                c.generate_box(f, (7, 2, 5), (7, 2, 7), p.gray, p.gray, false);
                c.generate_box(f, (5, 2, 7), (6, 2, 7), p.gray, p.gray, false);
                c.place(f, p.lamp, 6, 2, 6);
                if d.open[SOUTH] {
                    c.generate_box(f, (3, 3, 0), (4, 3, 0), p.light, p.light, false);
                } else {
                    c.generate_box(f, (3, 3, 0), (4, 3, 1), p.light, p.light, false);
                    c.generate_box(f, (3, 2, 0), (4, 2, 0), p.gray, p.gray, false);
                    c.generate_box(f, (3, 1, 0), (4, 1, 1), p.light, p.light, false);
                }
                if d.open[NORTH] {
                    c.generate_box(f, (3, 3, 7), (4, 3, 7), p.light, p.light, false);
                } else {
                    c.generate_box(f, (3, 3, 6), (4, 3, 7), p.light, p.light, false);
                    c.generate_box(f, (3, 2, 7), (4, 2, 7), p.gray, p.gray, false);
                    c.generate_box(f, (3, 1, 6), (4, 1, 7), p.light, p.light, false);
                }
                if d.open[WEST] {
                    c.generate_box(f, (0, 3, 3), (0, 3, 4), p.light, p.light, false);
                } else {
                    c.generate_box(f, (0, 3, 3), (1, 3, 4), p.light, p.light, false);
                    c.generate_box(f, (0, 2, 3), (0, 2, 4), p.gray, p.gray, false);
                    c.generate_box(f, (0, 1, 3), (1, 1, 4), p.light, p.light, false);
                }
                if d.open[EAST] {
                    c.generate_box(f, (7, 3, 3), (7, 3, 4), p.light, p.light, false);
                } else {
                    c.generate_box(f, (6, 3, 3), (7, 3, 4), p.light, p.light, false);
                    c.generate_box(f, (7, 2, 3), (7, 2, 4), p.gray, p.gray, false);
                    c.generate_box(f, (6, 1, 3), (7, 1, 4), p.light, p.light, false);
                }
            } else if design == 1 {
                c.generate_box(f, (2, 1, 2), (2, 3, 2), p.light, p.light, false);
                c.generate_box(f, (2, 1, 5), (2, 3, 5), p.light, p.light, false);
                c.generate_box(f, (5, 1, 5), (5, 3, 5), p.light, p.light, false);
                c.generate_box(f, (5, 1, 2), (5, 3, 2), p.light, p.light, false);
                c.place(f, p.lamp, 2, 2, 2);
                c.place(f, p.lamp, 2, 2, 5);
                c.place(f, p.lamp, 5, 2, 5);
                c.place(f, p.lamp, 5, 2, 2);
                c.generate_box(f, (0, 1, 0), (1, 3, 0), p.light, p.light, false);
                c.generate_box(f, (0, 1, 1), (0, 3, 1), p.light, p.light, false);
                c.generate_box(f, (0, 1, 7), (1, 3, 7), p.light, p.light, false);
                c.generate_box(f, (0, 1, 6), (0, 3, 6), p.light, p.light, false);
                c.generate_box(f, (6, 1, 7), (7, 3, 7), p.light, p.light, false);
                c.generate_box(f, (7, 1, 6), (7, 3, 6), p.light, p.light, false);
                c.generate_box(f, (6, 1, 0), (7, 3, 0), p.light, p.light, false);
                c.generate_box(f, (7, 1, 1), (7, 3, 1), p.light, p.light, false);
                c.place(f, p.gray, 1, 2, 0);
                c.place(f, p.gray, 0, 2, 1);
                c.place(f, p.gray, 1, 2, 7);
                c.place(f, p.gray, 0, 2, 6);
                c.place(f, p.gray, 6, 2, 7);
                c.place(f, p.gray, 7, 2, 6);
                c.place(f, p.gray, 6, 2, 0);
                c.place(f, p.gray, 7, 2, 1);
                if !d.open[SOUTH] {
                    c.generate_box(f, (1, 3, 0), (6, 3, 0), p.light, p.light, false);
                    c.generate_box(f, (1, 2, 0), (6, 2, 0), p.gray, p.gray, false);
                    c.generate_box(f, (1, 1, 0), (6, 1, 0), p.light, p.light, false);
                }
                if !d.open[NORTH] {
                    c.generate_box(f, (1, 3, 7), (6, 3, 7), p.light, p.light, false);
                    c.generate_box(f, (1, 2, 7), (6, 2, 7), p.gray, p.gray, false);
                    c.generate_box(f, (1, 1, 7), (6, 1, 7), p.light, p.light, false);
                }
                if !d.open[WEST] {
                    c.generate_box(f, (0, 3, 1), (0, 3, 6), p.light, p.light, false);
                    c.generate_box(f, (0, 2, 1), (0, 2, 6), p.gray, p.gray, false);
                    c.generate_box(f, (0, 1, 1), (0, 1, 6), p.light, p.light, false);
                }
                if !d.open[EAST] {
                    c.generate_box(f, (7, 3, 1), (7, 3, 6), p.light, p.light, false);
                    c.generate_box(f, (7, 2, 1), (7, 2, 6), p.gray, p.gray, false);
                    c.generate_box(f, (7, 1, 1), (7, 1, 6), p.light, p.light, false);
                }
            } else if design == 2 {
                c.generate_box(f, (0, 1, 0), (0, 1, 7), p.light, p.light, false);
                c.generate_box(f, (7, 1, 0), (7, 1, 7), p.light, p.light, false);
                c.generate_box(f, (1, 1, 0), (6, 1, 0), p.light, p.light, false);
                c.generate_box(f, (1, 1, 7), (6, 1, 7), p.light, p.light, false);
                c.generate_box(f, (0, 2, 0), (0, 2, 7), p.black, p.black, false);
                c.generate_box(f, (7, 2, 0), (7, 2, 7), p.black, p.black, false);
                c.generate_box(f, (1, 2, 0), (6, 2, 0), p.black, p.black, false);
                c.generate_box(f, (1, 2, 7), (6, 2, 7), p.black, p.black, false);
                c.generate_box(f, (0, 3, 0), (0, 3, 7), p.light, p.light, false);
                c.generate_box(f, (7, 3, 0), (7, 3, 7), p.light, p.light, false);
                c.generate_box(f, (1, 3, 0), (6, 3, 0), p.light, p.light, false);
                c.generate_box(f, (1, 3, 7), (6, 3, 7), p.light, p.light, false);
                c.generate_box(f, (0, 1, 3), (0, 2, 4), p.black, p.black, false);
                c.generate_box(f, (7, 1, 3), (7, 2, 4), p.black, p.black, false);
                c.generate_box(f, (3, 1, 0), (4, 2, 0), p.black, p.black, false);
                c.generate_box(f, (3, 1, 7), (4, 2, 7), p.black, p.black, false);
                if d.open[SOUTH] {
                    water_box(c, f, p, (3, 1, 0), (4, 2, 0));
                }
                if d.open[NORTH] {
                    water_box(c, f, p, (3, 1, 7), (4, 2, 7));
                }
                if d.open[WEST] {
                    water_box(c, f, p, (0, 1, 3), (0, 2, 4));
                }
                if d.open[EAST] {
                    water_box(c, f, p, (7, 1, 3), (7, 2, 4));
                }
            }
            if center_pillar {
                c.generate_box(f, (3, 1, 3), (4, 1, 4), p.light, p.light, false);
                c.generate_box(f, (3, 2, 3), (4, 2, 4), p.gray, p.gray, false);
                c.generate_box(f, (3, 3, 3), (4, 3, 4), p.light, p.light, false);
            }
        }
        RoomKind::SimpleTop => {
            if d.index / 25 > 0 {
                default_floor(c, f, p, 0, 0, d.open[DOWN]);
            }
            if d.conn[UP].is_none() {
                fill_only(c, f, p, (1, 4, 1), (6, 4, 6), p.gray);
            }
            for x in 1..=6 {
                for z in 1..=6 {
                    if c.random.next_int_bounded(3) != 0 {
                        let y0 = 2 + if c.random.next_int_bounded(4) == 0 {
                            0
                        } else {
                            1
                        };
                        let wet_sponge = p.wet_sponge;
                        c.generate_box(f, (x, y0, z), (x, 3, z), wet_sponge, wet_sponge, false);
                    }
                }
            }
            c.generate_box(f, (0, 1, 0), (0, 1, 7), p.light, p.light, false);
            c.generate_box(f, (7, 1, 0), (7, 1, 7), p.light, p.light, false);
            c.generate_box(f, (1, 1, 0), (6, 1, 0), p.light, p.light, false);
            c.generate_box(f, (1, 1, 7), (6, 1, 7), p.light, p.light, false);
            c.generate_box(f, (0, 2, 0), (0, 2, 7), p.black, p.black, false);
            c.generate_box(f, (7, 2, 0), (7, 2, 7), p.black, p.black, false);
            c.generate_box(f, (1, 2, 0), (6, 2, 0), p.black, p.black, false);
            c.generate_box(f, (1, 2, 7), (6, 2, 7), p.black, p.black, false);
            c.generate_box(f, (0, 3, 0), (0, 3, 7), p.light, p.light, false);
            c.generate_box(f, (7, 3, 0), (7, 3, 7), p.light, p.light, false);
            c.generate_box(f, (1, 3, 0), (6, 3, 0), p.light, p.light, false);
            c.generate_box(f, (1, 3, 7), (6, 3, 7), p.light, p.light, false);
            c.generate_box(f, (0, 1, 3), (0, 2, 4), p.black, p.black, false);
            c.generate_box(f, (7, 1, 3), (7, 2, 4), p.black, p.black, false);
            c.generate_box(f, (3, 1, 0), (4, 2, 0), p.black, p.black, false);
            c.generate_box(f, (3, 1, 7), (4, 2, 7), p.black, p.black, false);
            if d.open[SOUTH] {
                water_box(c, f, p, (3, 1, 0), (4, 2, 0));
            }
        }
        RoomKind::Wing(design) => {
            if design == 0 {
                for i in 0..4 {
                    c.generate_box(
                        f,
                        (10 - i, 3 - i, 20 - i),
                        (12 + i, 3 - i, 20),
                        p.light,
                        p.light,
                        false,
                    );
                }
                c.generate_box(f, (7, 0, 6), (15, 0, 16), p.light, p.light, false);
                c.generate_box(f, (6, 0, 6), (6, 3, 20), p.light, p.light, false);
                c.generate_box(f, (16, 0, 6), (16, 3, 20), p.light, p.light, false);
                c.generate_box(f, (7, 1, 7), (7, 1, 20), p.light, p.light, false);
                c.generate_box(f, (15, 1, 7), (15, 1, 20), p.light, p.light, false);
                c.generate_box(f, (7, 1, 6), (9, 3, 6), p.light, p.light, false);
                c.generate_box(f, (13, 1, 6), (15, 3, 6), p.light, p.light, false);
                c.generate_box(f, (8, 1, 7), (9, 1, 7), p.light, p.light, false);
                c.generate_box(f, (13, 1, 7), (14, 1, 7), p.light, p.light, false);
                c.generate_box(f, (9, 0, 5), (13, 0, 5), p.light, p.light, false);
                c.generate_box(f, (10, 0, 7), (12, 0, 7), p.black, p.black, false);
                c.generate_box(f, (8, 0, 10), (8, 0, 12), p.black, p.black, false);
                c.generate_box(f, (14, 0, 10), (14, 0, 12), p.black, p.black, false);
                for z in (7..=18).rev().step_by(3) {
                    c.place(f, p.lamp, 6, 3, z);
                    c.place(f, p.lamp, 16, 3, z);
                }
                c.place(f, p.lamp, 10, 0, 10);
                c.place(f, p.lamp, 12, 0, 10);
                c.place(f, p.lamp, 10, 0, 12);
                c.place(f, p.lamp, 12, 0, 12);
                c.place(f, p.lamp, 8, 3, 6);
                c.place(f, p.lamp, 14, 3, 6);
                c.place(f, p.light, 4, 2, 4);
                c.place(f, p.lamp, 4, 1, 4);
                c.place(f, p.light, 4, 0, 4);
                c.place(f, p.light, 18, 2, 4);
                c.place(f, p.lamp, 18, 1, 4);
                c.place(f, p.light, 18, 0, 4);
                c.place(f, p.light, 4, 2, 18);
                c.place(f, p.lamp, 4, 1, 18);
                c.place(f, p.light, 4, 0, 18);
                c.place(f, p.light, 18, 2, 18);
                c.place(f, p.lamp, 18, 1, 18);
                c.place(f, p.light, 18, 0, 18);
                c.place(f, p.light, 9, 7, 20);
                c.place(f, p.light, 13, 7, 20);
                c.generate_box(f, (6, 0, 21), (7, 4, 21), p.light, p.light, false);
                c.generate_box(f, (15, 0, 21), (16, 4, 21), p.light, p.light, false);
                spawn_elder(c, f, 11, 2, 16)?;
            } else if design == 1 {
                c.generate_box(f, (9, 3, 18), (13, 3, 20), p.light, p.light, false);
                c.generate_box(f, (9, 0, 18), (9, 2, 18), p.light, p.light, false);
                c.generate_box(f, (13, 0, 18), (13, 2, 18), p.light, p.light, false);
                let mut x = 9;
                for _ in 0..2 {
                    c.place(f, p.light, x, 6, 20);
                    c.place(f, p.lamp, x, 5, 20);
                    c.place(f, p.light, x, 4, 20);
                    x = 13;
                }
                c.generate_box(f, (7, 3, 7), (15, 3, 14), p.light, p.light, false);
                let mut x2 = 10;
                for _ in 0..2 {
                    c.generate_box(f, (x2, 0, 10), (x2, 6, 10), p.light, p.light, false);
                    c.generate_box(f, (x2, 0, 12), (x2, 6, 12), p.light, p.light, false);
                    c.place(f, p.lamp, x2, 0, 10);
                    c.place(f, p.lamp, x2, 0, 12);
                    c.place(f, p.lamp, x2, 4, 10);
                    c.place(f, p.lamp, x2, 4, 12);
                    x2 = 12;
                }
                x2 = 8;
                for _ in 0..2 {
                    c.generate_box(f, (x2, 0, 7), (x2, 2, 7), p.light, p.light, false);
                    c.generate_box(f, (x2, 0, 14), (x2, 2, 14), p.light, p.light, false);
                    x2 = 14;
                }
                c.generate_box(f, (8, 3, 8), (8, 3, 13), p.black, p.black, false);
                c.generate_box(f, (14, 3, 8), (14, 3, 13), p.black, p.black, false);
                spawn_elder(c, f, 11, 5, 13)?;
            }
        }
        RoomKind::Penthouse => {
            c.generate_box(f, (2, -1, 2), (11, -1, 11), p.light, p.light, false);
            c.generate_box(f, (0, -1, 0), (1, -1, 11), p.gray, p.gray, false);
            c.generate_box(f, (12, -1, 0), (13, -1, 11), p.gray, p.gray, false);
            c.generate_box(f, (2, -1, 0), (11, -1, 1), p.gray, p.gray, false);
            c.generate_box(f, (2, -1, 12), (11, -1, 13), p.gray, p.gray, false);
            c.generate_box(f, (0, 0, 0), (0, 0, 13), p.light, p.light, false);
            c.generate_box(f, (13, 0, 0), (13, 0, 13), p.light, p.light, false);
            c.generate_box(f, (1, 0, 0), (12, 0, 0), p.light, p.light, false);
            c.generate_box(f, (1, 0, 13), (12, 0, 13), p.light, p.light, false);
            for i in (2..=11).step_by(3) {
                c.place(f, p.lamp, 0, 0, i);
                c.place(f, p.lamp, 13, 0, i);
                c.place(f, p.lamp, i, 0, 0);
            }
            c.generate_box(f, (2, 0, 3), (4, 0, 9), p.light, p.light, false);
            c.generate_box(f, (9, 0, 3), (11, 0, 9), p.light, p.light, false);
            c.generate_box(f, (4, 0, 9), (9, 0, 11), p.light, p.light, false);
            c.place(f, p.light, 5, 0, 8);
            c.place(f, p.light, 8, 0, 8);
            c.place(f, p.light, 10, 0, 10);
            c.place(f, p.light, 3, 0, 10);
            c.generate_box(f, (3, 0, 3), (3, 0, 7), p.black, p.black, false);
            c.generate_box(f, (10, 0, 3), (10, 0, 7), p.black, p.black, false);
            c.generate_box(f, (6, 0, 10), (7, 0, 10), p.black, p.black, false);
            let mut x = 3;
            for _ in 0..2 {
                for z in (2..=8).step_by(3) {
                    c.generate_box(f, (x, 0, z), (x, 2, z), p.light, p.light, false);
                }
                x = 10;
            }
            c.generate_box(f, (5, 0, 10), (5, 2, 10), p.light, p.light, false);
            c.generate_box(f, (8, 0, 10), (8, 2, 10), p.light, p.light, false);
            c.generate_box(f, (6, -1, 7), (7, -1, 8), p.black, p.black, false);
            water_box(c, f, p, (6, -1, 3), (7, -1, 4));
            spawn_elder(c, f, 6, 1, 6)?;
        }
    }
    Ok(())
}
