//! Strongholds (VMC-025e4, `StrongholdStructure`, `StrongholdPieces`): a
//! staircase start at y 64 whose doors grow corridors, turns, crossings,
//! rooms, a library and the portal room from a weighted piece list (pending
//! children taken in random order), regenerated from the next seed until a
//! portal room exists, then moved below sea level.

use super::super::carver::set_large_feature_seed;
use super::super::random::Random;
use super::piece::{
    encapsulating, make_bounding_box, BoundingBox, Direction, Nbt, Piece, PieceKind,
};
use super::place::{Ctx, Frame};
use super::GenContext;

/// `SmallDoorType`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Door {
    Opening,
    WoodDoor,
    Grates,
    IronDoor,
}

impl Door {
    fn name(self) -> &'static str {
        match self {
            Door::Opening => "OPENING",
            Door::WoodDoor => "WOOD_DOOR",
            Door::Grates => "GRATES",
            Door::IronDoor => "IRON_DOOR",
        }
    }

    /// `randomSmallDoor`.
    fn random(random: &mut Random) -> Door {
        match random.next_int_bounded(5) {
            2 => Door::WoodDoor,
            3 => Door::Grates,
            4 => Door::IronDoor,
            _ => Door::Opening,
        }
    }
}

/// A stronghold piece's type and own fields.
#[derive(Clone, Debug, PartialEq)]
pub enum StrongholdKind {
    Start,
    Straight {
        left: bool,
        right: bool,
    },
    PrisonHall,
    LeftTurn,
    RightTurn,
    RoomCrossing {
        kind: i32,
    },
    StraightStairsDown,
    StairsDown,
    FiveCrossing {
        left_low: bool,
        left_high: bool,
        right_low: bool,
        right_high: bool,
    },
    ChestCorridor,
    Library {
        tall: bool,
    },
    PortalRoom,
    FillerCorridor {
        steps: i32,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct StrongholdPiece {
    pub kind: StrongholdKind,
    pub entry_door: Door,
    /// What placement has done once: a chest corridor's chest (`Chest`), the
    /// portal room's spawner (`Mob`).
    pub placed: bool,
}

impl StrongholdPiece {
    pub fn id(&self) -> &'static str {
        match self.kind {
            StrongholdKind::Start => "minecraft:shstart",
            StrongholdKind::Straight { .. } => "minecraft:shs",
            StrongholdKind::PrisonHall => "minecraft:shph",
            StrongholdKind::LeftTurn => "minecraft:shlt",
            StrongholdKind::RightTurn => "minecraft:shrt",
            StrongholdKind::RoomCrossing { .. } => "minecraft:shrc",
            StrongholdKind::StraightStairsDown => "minecraft:shssd",
            StrongholdKind::StairsDown => "minecraft:shsd",
            StrongholdKind::FiveCrossing { .. } => "minecraft:sh5c",
            StrongholdKind::ChestCorridor => "minecraft:shcc",
            StrongholdKind::Library { .. } => "minecraft:shli",
            StrongholdKind::PortalRoom => "minecraft:shpr",
            StrongholdKind::FillerCorridor { .. } => "minecraft:shfc",
        }
    }

    pub fn save(&self, put: &mut dyn FnMut(&str, Nbt)) {
        put("EntryDoor", Nbt::string(self.entry_door.name()));
        match self.kind {
            StrongholdKind::Start => put("Source", Nbt::bool(true)),
            StrongholdKind::StairsDown => put("Source", Nbt::bool(false)),
            StrongholdKind::Straight { left, right } => {
                put("Left", Nbt::bool(left));
                put("Right", Nbt::bool(right));
            }
            StrongholdKind::RoomCrossing { kind } => put("Type", Nbt::Int(kind)),
            StrongholdKind::FiveCrossing {
                left_low,
                left_high,
                right_low,
                right_high,
            } => {
                put("leftLow", Nbt::bool(left_low));
                put("leftHigh", Nbt::bool(left_high));
                put("rightLow", Nbt::bool(right_low));
                put("rightHigh", Nbt::bool(right_high));
            }
            StrongholdKind::ChestCorridor => put("Chest", Nbt::bool(self.placed)),
            StrongholdKind::Library { tall } => put("Tall", Nbt::bool(tall)),
            StrongholdKind::PortalRoom => put("Mob", Nbt::bool(self.placed)),
            StrongholdKind::FillerCorridor { steps } => put("Steps", Nbt::Int(steps)),
            StrongholdKind::PrisonHall
            | StrongholdKind::LeftTurn
            | StrongholdKind::RightTurn
            | StrongholdKind::StraightStairsDown => {}
        }
    }
}

/// The weighted piece types (`STRONGHOLD_PIECE_WEIGHTS`): weight and most
/// placements (0: unlimited).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Factory {
    Straight,
    PrisonHall,
    LeftTurn,
    RightTurn,
    RoomCrossing,
    StraightStairsDown,
    StairsDown,
    FiveCrossing,
    ChestCorridor,
    Library,
    PortalRoom,
}

const WEIGHTS: [(Factory, i32, i32); 11] = [
    (Factory::Straight, 40, 0),
    (Factory::PrisonHall, 5, 5),
    (Factory::LeftTurn, 20, 0),
    (Factory::RightTurn, 20, 0),
    (Factory::RoomCrossing, 10, 6),
    (Factory::StraightStairsDown, 5, 5),
    (Factory::StairsDown, 5, 5),
    (Factory::FiveCrossing, 5, 4),
    (Factory::ChestCorridor, 5, 4),
    (Factory::Library, 10, 2),
    (Factory::PortalRoom, 20, 1),
];

struct Layout<'a> {
    random: &'a mut Random,
    pieces: Vec<Piece>,
    /// Indices into `WEIGHTS` still in play, and per weight its placements.
    current: Vec<usize>,
    placed: [i32; 11],
    total_weight: i32,
    imposed: Option<Factory>,
    previous: Option<usize>,
    portal_room: bool,
    pending: Vec<usize>,
    start_min: (i32, i32),
}

fn sh(
    kind: StrongholdKind,
    door: Door,
    bbox: BoundingBox,
    direction: Direction,
    depth: i32,
) -> Piece {
    Piece {
        kind: PieceKind::Stronghold(StrongholdPiece {
            kind,
            entry_door: door,
            placed: false,
        }),
        bbox,
        orientation: Some(direction),
        gen_depth: depth,
    }
}

impl Layout<'_> {
    fn collides(&self, b: &BoundingBox) -> bool {
        self.pieces.iter().any(|p| p.bbox.intersects(b))
    }

    /// A piece's box when it is above y 10 and meets no other piece.
    fn free_box(
        &self,
        foot: [i32; 3],
        offset: (i32, i32, i32),
        size: (i32, i32, i32),
        direction: Direction,
    ) -> Option<BoundingBox> {
        let b = BoundingBox::orient(
            (foot[0], foot[1], foot[2]),
            offset,
            size.0,
            size.1,
            size.2,
            direction,
        );
        (b.min_y > 10 && !self.collides(&b)).then_some(b)
    }

    /// `findAndCreatePieceFactory`.
    fn create(
        &mut self,
        factory: Factory,
        foot: [i32; 3],
        direction: Direction,
        depth: i32,
    ) -> Option<Piece> {
        use StrongholdKind as K;
        let small = (-1, -1, 0);
        Some(match factory {
            Factory::Straight => {
                let b = self.free_box(foot, small, (5, 5, 7), direction)?;
                let door = Door::random(self.random);
                let left = self.random.next_int_bounded(2) == 0;
                let right = self.random.next_int_bounded(2) == 0;
                sh(K::Straight { left, right }, door, b, direction, depth)
            }
            Factory::PrisonHall => {
                let b = self.free_box(foot, small, (9, 5, 11), direction)?;
                sh(
                    K::PrisonHall,
                    Door::random(self.random),
                    b,
                    direction,
                    depth,
                )
            }
            Factory::LeftTurn => {
                let b = self.free_box(foot, small, (5, 5, 5), direction)?;
                sh(K::LeftTurn, Door::random(self.random), b, direction, depth)
            }
            Factory::RightTurn => {
                let b = self.free_box(foot, small, (5, 5, 5), direction)?;
                sh(K::RightTurn, Door::random(self.random), b, direction, depth)
            }
            Factory::RoomCrossing => {
                let b = self.free_box(foot, (-4, -1, 0), (11, 7, 11), direction)?;
                let door = Door::random(self.random);
                let kind = self.random.next_int_bounded(5);
                sh(K::RoomCrossing { kind }, door, b, direction, depth)
            }
            Factory::StraightStairsDown => {
                let b = self.free_box(foot, (-1, -7, 0), (5, 11, 8), direction)?;
                sh(
                    K::StraightStairsDown,
                    Door::random(self.random),
                    b,
                    direction,
                    depth,
                )
            }
            Factory::StairsDown => {
                let b = self.free_box(foot, (-1, -7, 0), (5, 11, 5), direction)?;
                sh(
                    K::StairsDown,
                    Door::random(self.random),
                    b,
                    direction,
                    depth,
                )
            }
            Factory::FiveCrossing => {
                let b = self.free_box(foot, (-4, -3, 0), (10, 9, 11), direction)?;
                let door = Door::random(self.random);
                let left_low = self.random.next_bool();
                let left_high = self.random.next_bool();
                let right_low = self.random.next_bool();
                let right_high = self.random.next_int_bounded(3) > 0;
                sh(
                    K::FiveCrossing {
                        left_low,
                        left_high,
                        right_low,
                        right_high,
                    },
                    door,
                    b,
                    direction,
                    depth,
                )
            }
            Factory::ChestCorridor => {
                let b = self.free_box(foot, small, (5, 5, 7), direction)?;
                sh(
                    K::ChestCorridor,
                    Door::random(self.random),
                    b,
                    direction,
                    depth,
                )
            }
            Factory::Library => {
                let b = self
                    .free_box(foot, (-4, -1, 0), (14, 11, 15), direction)
                    .or_else(|| self.free_box(foot, (-4, -1, 0), (14, 6, 15), direction))?;
                let door = Door::random(self.random);
                sh(
                    K::Library {
                        tall: b.y_span() > 6,
                    },
                    door,
                    b,
                    direction,
                    depth,
                )
            }
            Factory::PortalRoom => {
                let b = self.free_box(foot, (-4, -1, 0), (11, 8, 16), direction)?;
                sh(K::PortalRoom, Door::Opening, b, direction, depth)
            }
        })
    }

    fn may_place(&self, weight: usize, depth: i32) -> bool {
        let (factory, _, max) = WEIGHTS[weight];
        let base = max == 0 || self.placed[weight] < max;
        base && match factory {
            Factory::Library => depth > 4,
            Factory::PortalRoom => depth > 5,
            _ => true,
        }
    }

    /// `generatePieceFromSmallDoor`.
    fn small_door_piece(
        &mut self,
        foot: [i32; 3],
        direction: Direction,
        depth: i32,
    ) -> Option<Piece> {
        // `updatePieceWeight`.
        let mut any = false;
        self.total_weight = 0;
        for &w in &self.current {
            let (_, weight, max) = WEIGHTS[w];
            if max > 0 && self.placed[w] < max {
                any = true;
            }
            self.total_weight += weight;
        }
        if !any {
            return None;
        }
        if let Some(factory) = self.imposed.take() {
            if let Some(piece) = self.create(factory, foot, direction, depth) {
                return Some(piece);
            }
        }
        for _ in 0..5 {
            let mut selection = self.random.next_int_bounded(self.total_weight);
            let mut i = 0;
            while i < self.current.len() {
                let w = self.current[i];
                selection -= WEIGHTS[w].1;
                if selection < 0 {
                    if !self.may_place(w, depth) || Some(w) == self.previous {
                        break;
                    }
                    if let Some(piece) = self.create(WEIGHTS[w].0, foot, direction, depth) {
                        self.placed[w] += 1;
                        self.previous = Some(w);
                        let max = WEIGHTS[w].2;
                        if !(max == 0 || self.placed[w] < max) {
                            self.current.remove(i);
                        }
                        return Some(piece);
                    }
                }
                i += 1;
            }
        }
        // `FillerCorridor.findPieceBox`.
        let probe =
            BoundingBox::orient((foot[0], foot[1], foot[2]), (-1, -1, 0), 5, 5, 4, direction);
        let other = self.pieces.iter().find(|p| p.bbox.intersects(&probe))?.bbox;
        if other.min_y != probe.min_y {
            return None;
        }
        for length in (1..=2).rev() {
            let b = BoundingBox::orient(
                (foot[0], foot[1], foot[2]),
                (-1, -1, 0),
                5,
                5,
                length,
                direction,
            );
            if !other.intersects(&b) {
                let b = BoundingBox::orient(
                    (foot[0], foot[1], foot[2]),
                    (-1, -1, 0),
                    5,
                    5,
                    length + 1,
                    direction,
                );
                if b.min_y <= 1 {
                    return None;
                }
                let steps = if direction.is_z() {
                    b.z_span()
                } else {
                    b.x_span()
                };
                return Some(sh(
                    StrongholdKind::FillerCorridor { steps },
                    Door::Opening,
                    b,
                    direction,
                    depth,
                ));
            }
        }
        None
    }

    /// `generateAndAddPiece`.
    fn add(&mut self, foot: [i32; 3], direction: Direction, depth: i32) {
        if depth > 50 {
            return;
        }
        if (foot[0] - self.start_min.0).abs() > 112 || (foot[2] - self.start_min.1).abs() > 112 {
            return;
        }
        if let Some(piece) = self.small_door_piece(foot, direction, depth + 1) {
            self.pieces.push(piece);
            self.pending.push(self.pieces.len() - 1);
        }
    }

    fn forward(&mut self, index: usize, x_off: i32, y_off: i32) {
        let p = &self.pieces[index];
        let (b, depth) = (p.bbox, p.gen_depth);
        let Some(o) = p.orientation else { return };
        let foot = match o {
            Direction::North => [b.min_x + x_off, b.min_y + y_off, b.min_z - 1],
            Direction::South => [b.min_x + x_off, b.min_y + y_off, b.max_z + 1],
            Direction::West => [b.min_x - 1, b.min_y + y_off, b.min_z + x_off],
            Direction::East => [b.max_x + 1, b.min_y + y_off, b.min_z + x_off],
        };
        self.add(foot, o, depth);
    }

    fn left(&mut self, index: usize, y_off: i32, z_off: i32) {
        let p = &self.pieces[index];
        let (b, depth) = (p.bbox, p.gen_depth);
        let Some(o) = p.orientation else { return };
        let (foot, direction) = match o {
            Direction::North | Direction::South => (
                [b.min_x - 1, b.min_y + y_off, b.min_z + z_off],
                Direction::West,
            ),
            Direction::West | Direction::East => (
                [b.min_x + z_off, b.min_y + y_off, b.min_z - 1],
                Direction::North,
            ),
        };
        self.add(foot, direction, depth);
    }

    fn right(&mut self, index: usize, y_off: i32, z_off: i32) {
        let p = &self.pieces[index];
        let (b, depth) = (p.bbox, p.gen_depth);
        let Some(o) = p.orientation else { return };
        let (foot, direction) = match o {
            Direction::North | Direction::South => (
                [b.max_x + 1, b.min_y + y_off, b.min_z + z_off],
                Direction::East,
            ),
            Direction::West | Direction::East => (
                [b.min_x + z_off, b.min_y + y_off, b.max_z + 1],
                Direction::South,
            ),
        };
        self.add(foot, direction, depth);
    }

    fn add_children(&mut self, index: usize) {
        let PieceKind::Stronghold(p) = &self.pieces[index].kind else {
            return;
        };
        let orientation = self.pieces[index].orientation;
        match p.kind.clone() {
            StrongholdKind::Start => {
                self.imposed = Some(Factory::FiveCrossing);
                self.forward(index, 1, 1);
            }
            StrongholdKind::StairsDown
            | StrongholdKind::ChestCorridor
            | StrongholdKind::PrisonHall
            | StrongholdKind::StraightStairsDown => self.forward(index, 1, 1),
            StrongholdKind::Straight { left, right } => {
                self.forward(index, 1, 1);
                if left {
                    self.left(index, 1, 2);
                }
                if right {
                    self.right(index, 1, 2);
                }
            }
            StrongholdKind::LeftTurn => {
                if !matches!(orientation, Some(Direction::North | Direction::East)) {
                    self.right(index, 1, 1);
                } else {
                    self.left(index, 1, 1);
                }
            }
            StrongholdKind::RightTurn => {
                if !matches!(orientation, Some(Direction::North | Direction::East)) {
                    self.left(index, 1, 1);
                } else {
                    self.right(index, 1, 1);
                }
            }
            StrongholdKind::RoomCrossing { .. } => {
                self.forward(index, 4, 1);
                self.left(index, 1, 4);
                self.right(index, 1, 4);
            }
            StrongholdKind::FiveCrossing {
                left_low,
                left_high,
                right_low,
                right_high,
            } => {
                let (mut a, mut b) = (3, 5);
                if matches!(orientation, Some(Direction::West | Direction::North)) {
                    a = 8 - a;
                    b = 8 - b;
                }
                self.forward(index, 5, 1);
                if left_low {
                    self.left(index, a, 1);
                }
                if left_high {
                    self.left(index, b, 7);
                }
                if right_low {
                    self.right(index, a, 1);
                }
                if right_high {
                    self.right(index, b, 7);
                }
            }
            StrongholdKind::PortalRoom => self.portal_room = true,
            StrongholdKind::Library { .. } | StrongholdKind::FillerCorridor { .. } => {}
        }
    }
}

/// `StrongholdStructure.generatePieces`, after the biome check at the
/// chunk's corner.
pub fn generate(gc: &mut GenContext) -> Result<Option<Vec<Piece>>, String> {
    if !gc.is_valid_biome((gc.min_block_x(), 0, gc.min_block_z())) {
        return Ok(None);
    }
    let (min_x, min_z) = (gc.min_block_x(), gc.min_block_z());
    let sea_level = gc.sea_level();
    let min_y = gc.env.heights.min_y;
    let seed = gc.env.seed;
    let mut tries: i64 = 0;
    loop {
        set_large_feature_seed(
            &mut gc.random,
            seed.wrapping_add(tries),
            gc.chunk.0,
            gc.chunk.1,
        );
        tries += 1;
        let direction = Direction::random(&mut gc.random);
        let start = Piece {
            kind: PieceKind::Stronghold(StrongholdPiece {
                kind: StrongholdKind::Start,
                entry_door: Door::Opening,
                placed: false,
            }),
            bbox: make_bounding_box(min_x + 2, 64, min_z + 2, direction, 5, 11, 5),
            orientation: Some(direction),
            gen_depth: 0,
        };
        let start_min = (start.bbox.min_x, start.bbox.min_z);
        let mut layout = Layout {
            random: &mut gc.random,
            pieces: vec![start],
            current: (0..WEIGHTS.len()).collect(),
            placed: [0; 11],
            total_weight: 0,
            imposed: None,
            previous: None,
            portal_room: false,
            pending: Vec::new(),
            start_min,
        };
        layout.add_children(0);
        while !layout.pending.is_empty() {
            let pos = layout.random.next_int_bounded(layout.pending.len() as i32) as usize;
            let index = layout.pending.remove(pos);
            layout.add_children(index);
        }
        let portal_room = layout.portal_room;
        let mut pieces = layout.pieces;
        // `moveBelowSeaLevel`.
        let bb = encapsulating(pieces.iter().map(|p| &p.bbox)).expect("a start");
        let max_y = sea_level - 10;
        let mut y1 = bb.y_span() + min_y + 1;
        if y1 < max_y {
            y1 += gc.random.next_int_bounded(max_y - y1);
        }
        let dy = y1 - bb.max_y;
        for p in &mut pieces {
            p.moved_by(0, dy, 0);
        }
        if !pieces.is_empty() && portal_room {
            return Ok(Some(pieces));
        }
    }
}

// Placement (VMC-025f4): each piece's `postProcess`.

const CORRIDOR_LOOT: &str = "minecraft:chests/stronghold_corridor";
const LIBRARY_LOOT: &str = "minecraft:chests/stronghold_library";
const CROSSING_LOOT: &str = "minecraft:chests/stronghold_crossing";

/// A stronghold piece's `postProcess`.
pub fn post_process(piece: &mut Piece, c: &mut Ctx) -> Result<(), String> {
    let PieceKind::Stronghold(s) = &mut piece.kind else {
        return Err("not a stronghold piece".into());
    };
    let f = Frame::new(piece.bbox, piece.orientation);
    let air = c.state("cave_air")?;
    let bricks = c.state("stone_bricks")?;
    let slab = c.state("smooth_stone_slab")?;
    let door = s.entry_door;
    // `SmoothStoneSelector`: the edges cracked, mossy, infested or plain
    // stone bricks, the inside cave air.
    let stones = [
        c.state("cracked_stone_bricks")?,
        c.state("mossy_stone_bricks")?,
        c.state("infested_stone_bricks")?,
        bricks,
    ];
    let mut smooth = move |random: &mut Random, _: [i32; 3], edge: bool| {
        if !edge {
            return air;
        }
        let selection = random.next_float();
        if selection < 0.2 {
            stones[0]
        } else if selection < 0.5 {
            stones[1]
        } else if selection < 0.55 {
            stones[2]
        } else {
            stones[3]
        }
    };
    let torch = |c: &Ctx, facing: &'static str| -> Result<u16, String> {
        Ok(c.placer.with(c.state("wall_torch")?, "facing", facing))
    };
    match s.kind.clone() {
        StrongholdKind::Start | StrongholdKind::StairsDown => {
            c.generate_box_with(&f, (0, 0, 0), (4, 10, 4), true, &mut smooth);
            small_door(c, &f, door, 1, 7, 0)?;
            small_door(c, &f, Door::Opening, 1, 1, 4)?;
            for (state, x, y, z) in [
                (bricks, 2, 6, 1),
                (bricks, 1, 5, 1),
                (slab, 1, 6, 1),
                (bricks, 1, 5, 2),
                (bricks, 1, 4, 3),
                (slab, 1, 5, 3),
                (bricks, 2, 4, 3),
                (bricks, 3, 3, 3),
                (slab, 3, 4, 3),
                (bricks, 3, 3, 2),
                (bricks, 3, 2, 1),
                (slab, 3, 3, 1),
                (bricks, 2, 2, 1),
                (bricks, 1, 1, 1),
                (slab, 1, 2, 1),
                (bricks, 1, 1, 2),
                (slab, 1, 1, 3),
            ] {
                c.place(&f, state, x, y, z);
            }
        }
        StrongholdKind::Straight { left, right } => {
            c.generate_box_with(&f, (0, 0, 0), (4, 4, 6), true, &mut smooth);
            small_door(c, &f, door, 1, 1, 0)?;
            small_door(c, &f, Door::Opening, 1, 1, 6)?;
            let (east, west) = (torch(c, "east")?, torch(c, "west")?);
            c.maybe_block(&f, 0.1, 1, 2, 1, east);
            c.maybe_block(&f, 0.1, 3, 2, 1, west);
            c.maybe_block(&f, 0.1, 1, 2, 5, east);
            c.maybe_block(&f, 0.1, 3, 2, 5, west);
            if left {
                c.generate_box(&f, (0, 1, 2), (0, 3, 4), air, air, false);
            }
            if right {
                c.generate_box(&f, (4, 1, 2), (4, 3, 4), air, air, false);
            }
        }
        StrongholdKind::ChestCorridor => {
            c.generate_box_with(&f, (0, 0, 0), (4, 4, 6), true, &mut smooth);
            small_door(c, &f, door, 1, 1, 0)?;
            small_door(c, &f, Door::Opening, 1, 1, 6)?;
            c.generate_box(&f, (3, 1, 2), (3, 1, 4), bricks, bricks, false);
            let brick_slab = c.state("stone_brick_slab")?;
            for (x, y, z) in [
                (3, 1, 1),
                (3, 1, 5),
                (3, 2, 2),
                (3, 2, 4),
                (2, 1, 2),
                (2, 1, 3),
                (2, 1, 4),
            ] {
                c.place(&f, brick_slab, x, y, z);
            }
            let chest = f.world(3, 2, 3);
            if !s.placed && c.chunk_box.is_inside(chest[0], chest[1], chest[2]) {
                s.placed = true;
                c.create_chest_at(&f, 3, 2, 3, CORRIDOR_LOOT)?;
            }
        }
        StrongholdKind::FillerCorridor { steps } => {
            for i in 0..steps {
                for x in 0..=4 {
                    c.place(&f, bricks, x, 0, i);
                }
                for y in 1..=3 {
                    c.place(&f, bricks, 0, y, i);
                    for x in 1..=3 {
                        c.place(&f, air, x, y, i);
                    }
                    c.place(&f, bricks, 4, y, i);
                }
                for x in 0..=4 {
                    c.place(&f, bricks, x, 4, i);
                }
            }
        }
        StrongholdKind::FiveCrossing {
            left_low,
            left_high,
            right_low,
            right_high,
        } => {
            c.generate_box_with(&f, (0, 0, 0), (9, 8, 10), true, &mut smooth);
            small_door(c, &f, door, 4, 3, 0)?;
            if left_low {
                c.generate_box(&f, (0, 3, 1), (0, 5, 3), air, air, false);
            }
            if right_low {
                c.generate_box(&f, (9, 3, 1), (9, 5, 3), air, air, false);
            }
            if left_high {
                c.generate_box(&f, (0, 5, 7), (0, 7, 9), air, air, false);
            }
            if right_high {
                c.generate_box(&f, (9, 5, 7), (9, 7, 9), air, air, false);
            }
            c.generate_box(&f, (5, 1, 10), (7, 3, 10), air, air, false);
            c.generate_box_with(&f, (1, 2, 1), (8, 2, 6), false, &mut smooth);
            c.generate_box_with(&f, (4, 1, 5), (4, 4, 9), false, &mut smooth);
            c.generate_box_with(&f, (8, 1, 5), (8, 4, 9), false, &mut smooth);
            c.generate_box_with(&f, (1, 4, 7), (3, 4, 9), false, &mut smooth);
            c.generate_box_with(&f, (1, 3, 5), (3, 3, 6), false, &mut smooth);
            c.generate_box(&f, (1, 3, 4), (3, 3, 4), slab, slab, false);
            c.generate_box(&f, (1, 4, 6), (3, 4, 6), slab, slab, false);
            c.generate_box_with(&f, (5, 1, 7), (7, 1, 8), false, &mut smooth);
            c.generate_box(&f, (5, 1, 9), (7, 1, 9), slab, slab, false);
            c.generate_box(&f, (5, 2, 7), (7, 2, 7), slab, slab, false);
            c.generate_box(&f, (4, 5, 7), (4, 5, 9), slab, slab, false);
            c.generate_box(&f, (8, 5, 7), (8, 5, 9), slab, slab, false);
            let double = c.placer.with(slab, "type", "double");
            c.generate_box(&f, (5, 5, 7), (7, 5, 9), double, double, false);
            let south = torch(c, "south")?;
            c.place(&f, south, 6, 5, 6);
        }
        StrongholdKind::LeftTurn | StrongholdKind::RightTurn => {
            c.generate_box_with(&f, (0, 0, 0), (4, 4, 4), true, &mut smooth);
            small_door(c, &f, door, 1, 1, 0)?;
            let north_or_east =
                matches!(piece.orientation, Some(Direction::North | Direction::East));
            let left = matches!(s.kind, StrongholdKind::LeftTurn);
            // A left turn opens west of its frame facing north or east,
            // east otherwise; a right turn the other way.
            if north_or_east == left {
                c.generate_box(&f, (0, 1, 1), (0, 3, 3), air, air, false);
            } else {
                c.generate_box(&f, (4, 1, 1), (4, 3, 3), air, air, false);
            }
        }
        StrongholdKind::Library { tall } => library(c, &f, door, tall, &mut smooth)?,
        StrongholdKind::PortalRoom => {
            let placed = portal_room(c, &f, s.placed, &mut smooth)?;
            s.placed = placed;
        }
        StrongholdKind::PrisonHall => {
            c.generate_box_with(&f, (0, 0, 0), (8, 4, 10), true, &mut smooth);
            small_door(c, &f, door, 1, 1, 0)?;
            c.generate_box(&f, (1, 1, 10), (3, 3, 10), air, air, false);
            c.generate_box_with(&f, (4, 1, 1), (4, 3, 1), false, &mut smooth);
            c.generate_box_with(&f, (4, 1, 3), (4, 3, 3), false, &mut smooth);
            c.generate_box_with(&f, (4, 1, 7), (4, 3, 7), false, &mut smooth);
            c.generate_box_with(&f, (4, 1, 9), (4, 3, 9), false, &mut smooth);
            let ns = c.state("iron_bars[north=true,south=true]")?;
            let nse = c.state("iron_bars[north=true,south=true,east=true]")?;
            let we = c.state("iron_bars[west=true,east=true]")?;
            for y in 1..=3 {
                c.place(&f, ns, 4, y, 4);
                c.place(&f, nse, 4, y, 5);
                c.place(&f, ns, 4, y, 6);
                c.place(&f, we, 5, y, 5);
                c.place(&f, we, 6, y, 5);
                c.place(&f, we, 7, y, 5);
            }
            c.place(&f, ns, 4, 3, 2);
            c.place(&f, ns, 4, 3, 8);
            let bottom = c.state("iron_door[facing=west]")?;
            let top = c.state("iron_door[facing=west,half=upper]")?;
            c.place(&f, bottom, 4, 1, 2);
            c.place(&f, top, 4, 2, 2);
            c.place(&f, bottom, 4, 1, 8);
            c.place(&f, top, 4, 2, 8);
        }
        StrongholdKind::RoomCrossing { kind } => room_crossing(c, &f, door, kind, &mut smooth)?,
        StrongholdKind::StraightStairsDown => {
            c.generate_box_with(&f, (0, 0, 0), (4, 10, 7), true, &mut smooth);
            small_door(c, &f, door, 1, 7, 0)?;
            small_door(c, &f, Door::Opening, 1, 1, 7)?;
            let stairs = c.state("cobblestone_stairs[facing=south]")?;
            for i in 0..6 {
                for x in 1..=3 {
                    c.place(&f, stairs, x, 6 - i, 1 + i);
                }
                if i < 5 {
                    for x in 1..=3 {
                        c.place(&f, bricks, x, 5 - i, 1 + i);
                    }
                }
            }
        }
    }
    Ok(())
}

/// `generateSmallDoor`.
fn small_door(c: &mut Ctx, f: &Frame, door: Door, x: i32, y: i32, z: i32) -> Result<(), String> {
    let bricks = c.state("stone_bricks")?;
    let frame = |c: &mut Ctx| {
        for (dx, dy) in [(0, 0), (0, 1), (0, 2), (1, 2), (2, 2), (2, 1), (2, 0)] {
            c.place(f, bricks, x + dx, y + dy, z);
        }
    };
    match door {
        Door::Opening => {
            let air = c.state("cave_air")?;
            c.generate_box(f, (x, y, z), (x + 2, y + 2, z), air, air, false);
        }
        Door::WoodDoor => {
            frame(c);
            let lower = c.state("oak_door")?;
            let upper = c.state("oak_door[half=upper]")?;
            c.place(f, lower, x + 1, y, z);
            c.place(f, upper, x + 1, y + 1, z);
        }
        Door::Grates => {
            let air = c.state("cave_air")?;
            let west = c.state("iron_bars[west=true]")?;
            let both = c.state("iron_bars[east=true,west=true]")?;
            let east = c.state("iron_bars[east=true]")?;
            c.place(f, air, x + 1, y, z);
            c.place(f, air, x + 1, y + 1, z);
            c.place(f, west, x, y, z);
            c.place(f, west, x, y + 1, z);
            c.place(f, both, x, y + 2, z);
            c.place(f, both, x + 1, y + 2, z);
            c.place(f, both, x + 2, y + 2, z);
            c.place(f, east, x + 2, y + 1, z);
            c.place(f, east, x + 2, y, z);
        }
        Door::IronDoor => {
            frame(c);
            let lower = c.state("iron_door")?;
            let upper = c.state("iron_door[half=upper]")?;
            let north = c.state("stone_button[facing=north]")?;
            let south = c.state("stone_button[facing=south]")?;
            c.place(f, lower, x + 1, y, z);
            c.place(f, upper, x + 1, y + 1, z);
            c.place(f, north, x + 2, y + 1, z + 1);
            c.place(f, south, x + 2, y + 1, z - 1);
        }
    }
    Ok(())
}

/// `Library.postProcess`: bookshelf walls and rows, cobwebs, in a tall
/// library a gallery with a chandelier and a second chest.
fn library(
    c: &mut Ctx,
    f: &Frame,
    door: Door,
    tall: bool,
    smooth: &mut super::place::Selector,
) -> Result<(), String> {
    let height = if tall { 11 } else { 6 };
    c.generate_box_with(f, (0, 0, 0), (13, height - 1, 14), true, smooth);
    small_door(c, f, door, 4, 1, 0)?;
    let cobweb = c.state("cobweb")?;
    c.maybe_box(
        f,
        0.07,
        (2, 1, 1),
        (11, 4, 13),
        cobweb,
        cobweb,
        false,
        false,
    );
    let planks = c.state("oak_planks")?;
    let shelf = c.state("bookshelf")?;
    let east = c.placer.with(c.state("wall_torch")?, "facing", "east");
    let west = c.placer.with(c.state("wall_torch")?, "facing", "west");
    for d in 1..=13 {
        let state = if (d - 1) % 4 == 0 { planks } else { shelf };
        c.generate_box(f, (1, 1, d), (1, 4, d), state, state, false);
        c.generate_box(f, (12, 1, d), (12, 4, d), state, state, false);
        if state == planks {
            c.place(f, east, 2, 3, d);
            c.place(f, west, 11, 3, d);
        }
        if tall {
            c.generate_box(f, (1, 6, d), (1, 9, d), state, state, false);
            c.generate_box(f, (12, 6, d), (12, 9, d), state, state, false);
        }
    }
    for d in (3..12).step_by(2) {
        c.generate_box(f, (3, 1, d), (4, 3, d), shelf, shelf, false);
        c.generate_box(f, (6, 1, d), (7, 3, d), shelf, shelf, false);
        c.generate_box(f, (9, 1, d), (10, 3, d), shelf, shelf, false);
    }
    if tall {
        c.generate_box(f, (1, 5, 1), (3, 5, 13), planks, planks, false);
        c.generate_box(f, (10, 5, 1), (12, 5, 13), planks, planks, false);
        c.generate_box(f, (4, 5, 1), (9, 5, 2), planks, planks, false);
        c.generate_box(f, (4, 5, 12), (9, 5, 13), planks, planks, false);
        c.place(f, planks, 9, 5, 11);
        c.place(f, planks, 8, 5, 11);
        c.place(f, planks, 9, 5, 10);
        let fence = |c: &Ctx, spec: &'static str| c.state(spec);
        let we = fence(c, "oak_fence[west=true,east=true]")?;
        let ns = fence(c, "oak_fence[north=true,south=true]")?;
        c.generate_box(f, (3, 6, 3), (3, 6, 11), ns, ns, false);
        c.generate_box(f, (10, 6, 3), (10, 6, 9), ns, ns, false);
        c.generate_box(f, (4, 6, 2), (9, 6, 2), we, we, false);
        c.generate_box(f, (4, 6, 12), (7, 6, 12), we, we, false);
        let ne = fence(c, "oak_fence[north=true,east=true]")?;
        let se = fence(c, "oak_fence[south=true,east=true]")?;
        let nw = fence(c, "oak_fence[north=true,west=true]")?;
        let sw = fence(c, "oak_fence[south=true,west=true]")?;
        c.place(f, ne, 3, 6, 2);
        c.place(f, se, 3, 6, 12);
        c.place(f, nw, 10, 6, 2);
        for i in 0..=2 {
            c.place(f, sw, 8 + i, 6, 12 - i);
            if i != 2 {
                c.place(f, ne, 8 + i, 6, 11 - i);
            }
        }
        let ladder = c.state("ladder[facing=south]")?;
        for y in 1..=7 {
            c.place(f, ladder, 10, y, 13);
        }
        let e = fence(c, "oak_fence[east=true]")?;
        let w = fence(c, "oak_fence[west=true]")?;
        c.place(f, e, 6, 9, 7);
        c.place(f, w, 7, 9, 7);
        c.place(f, e, 6, 8, 7);
        c.place(f, w, 7, 8, 7);
        let nswe = fence(c, "oak_fence[north=true,south=true,west=true,east=true]")?;
        c.place(f, nswe, 6, 7, 7);
        c.place(f, nswe, 7, 7, 7);
        c.place(f, e, 5, 7, 7);
        c.place(f, w, 8, 7, 7);
        let en = fence(c, "oak_fence[east=true,north=true]")?;
        let es = fence(c, "oak_fence[east=true,south=true]")?;
        let wn = fence(c, "oak_fence[west=true,north=true]")?;
        let ws = fence(c, "oak_fence[west=true,south=true]")?;
        c.place(f, en, 6, 7, 6);
        c.place(f, es, 6, 7, 8);
        c.place(f, wn, 7, 7, 6);
        c.place(f, ws, 7, 7, 8);
        let torch = c.state("torch")?;
        for (x, z) in [(5, 7), (8, 7), (6, 6), (6, 8), (7, 6), (7, 8)] {
            c.place(f, torch, x, 8, z);
        }
    }
    c.create_chest_at(f, 3, 3, 5, LIBRARY_LOOT)?;
    if tall {
        let air = c.state("cave_air")?;
        c.place(f, air, 12, 9, 1);
        c.create_chest_at(f, 12, 8, 1, LIBRARY_LOOT)?;
    }
    Ok(())
}

/// `PortalRoom.postProcess`: lava pools, the stairs up, the end portal
/// frame with eyes a tenth of the time each (the portal itself when all
/// twelve have them) and the silverfish spawner; whether the spawner is
/// placed now.
fn portal_room(
    c: &mut Ctx,
    f: &Frame,
    placed: bool,
    smooth: &mut super::place::Selector,
) -> Result<bool, String> {
    c.generate_box_with(f, (0, 0, 0), (10, 7, 15), false, smooth);
    small_door(c, f, Door::Grates, 4, 1, 0)?;
    for (from, to) in [
        ((1, 6, 1), (1, 6, 14)),
        ((9, 6, 1), (9, 6, 14)),
        ((2, 6, 1), (8, 6, 2)),
        ((2, 6, 14), (8, 6, 14)),
        ((1, 1, 1), (2, 1, 4)),
        ((8, 1, 1), (9, 1, 4)),
    ] {
        c.generate_box_with(f, from, to, false, smooth);
    }
    let lava = c.state("lava")?;
    c.generate_box(f, (1, 1, 1), (1, 1, 3), lava, lava, false);
    c.generate_box(f, (9, 1, 1), (9, 1, 3), lava, lava, false);
    c.generate_box_with(f, (3, 1, 8), (7, 1, 12), false, smooth);
    c.generate_box(f, (4, 1, 9), (6, 1, 11), lava, lava, false);
    let ns = c.state("iron_bars[north=true,south=true]")?;
    let we = c.state("iron_bars[west=true,east=true]")?;
    for z in (3..14).step_by(2) {
        c.generate_box(f, (0, 3, z), (0, 4, z), ns, ns, false);
        c.generate_box(f, (10, 3, z), (10, 4, z), ns, ns, false);
    }
    for x in (2..9).step_by(2) {
        c.generate_box(f, (x, 3, 15), (x, 4, 15), we, we, false);
    }
    let stairs = c.state("stone_brick_stairs[facing=north]")?;
    c.generate_box_with(f, (4, 1, 5), (6, 1, 7), false, smooth);
    c.generate_box_with(f, (4, 2, 6), (6, 2, 7), false, smooth);
    c.generate_box_with(f, (4, 3, 7), (6, 3, 7), false, smooth);
    for x in 4..=6 {
        c.place(f, stairs, x, 1, 4);
        c.place(f, stairs, x, 2, 5);
        c.place(f, stairs, x, 3, 6);
    }
    let mut eyes = [false; 12];
    for eye in eyes.iter_mut() {
        *eye = c.random.next_float() > 0.9;
    }
    let all = eyes.iter().all(|&e| e);
    let frame = c.state("end_portal_frame")?;
    let frames = [
        ("north", 4, 8),
        ("north", 5, 8),
        ("north", 6, 8),
        ("south", 4, 12),
        ("south", 5, 12),
        ("south", 6, 12),
        ("east", 3, 9),
        ("east", 3, 10),
        ("east", 3, 11),
        ("west", 7, 9),
        ("west", 7, 10),
        ("west", 7, 11),
    ];
    for (i, (facing, x, z)) in frames.into_iter().enumerate() {
        let state = c.placer.with(frame, "facing", facing);
        let state = c
            .placer
            .with(state, "eye", if eyes[i] { "true" } else { "false" });
        c.place(f, state, x, 3, z);
    }
    if all {
        let portal = c.state("end_portal")?;
        for z in 9..=11 {
            for x in 4..=6 {
                c.place(f, portal, x, 3, z);
            }
        }
    }
    if placed {
        return Ok(true);
    }
    let pos = f.world(5, 3, 6);
    if !c.chunk_box.is_inside(pos[0], pos[1], pos[2]) {
        return Ok(false);
    }
    let spawner = c.state("spawner")?;
    c.set(pos, spawner, 2);
    if let Some(entity) = c.region.block_entity(pos)? {
        if entity.kind == "minecraft:mob_spawner" {
            entity.spawner_entity = Some("minecraft:silverfish".into());
        }
    }
    Ok(true)
}

/// `RoomCrossing.postProcess`: a pillar with torches, a fountain, or a
/// gallery with a chest.
fn room_crossing(
    c: &mut Ctx,
    f: &Frame,
    door: Door,
    kind: i32,
    smooth: &mut super::place::Selector,
) -> Result<(), String> {
    c.generate_box_with(f, (0, 0, 0), (10, 6, 10), true, smooth);
    small_door(c, f, door, 4, 1, 0)?;
    let air = c.state("cave_air")?;
    c.generate_box(f, (4, 1, 10), (6, 3, 10), air, air, false);
    c.generate_box(f, (0, 1, 4), (0, 3, 6), air, air, false);
    c.generate_box(f, (10, 1, 4), (10, 3, 6), air, air, false);
    let bricks = c.state("stone_bricks")?;
    let torch = |c: &Ctx, facing: &'static str| -> Result<u16, String> {
        Ok(c.placer.with(c.state("wall_torch")?, "facing", facing))
    };
    match kind {
        0 => {
            for y in 1..=3 {
                c.place(f, bricks, 5, y, 5);
            }
            for (facing, x, z) in [
                ("west", 4, 5),
                ("east", 6, 5),
                ("south", 5, 4),
                ("north", 5, 6),
            ] {
                let state = torch(c, facing)?;
                c.place(f, state, x, 3, z);
            }
            let slab = c.state("smooth_stone_slab")?;
            for (x, z) in [
                (4, 4),
                (4, 5),
                (4, 6),
                (6, 4),
                (6, 5),
                (6, 6),
                (5, 4),
                (5, 6),
            ] {
                c.place(f, slab, x, 1, z);
            }
        }
        1 => {
            for i in 0..5 {
                c.place(f, bricks, 3, 1, 3 + i);
                c.place(f, bricks, 7, 1, 3 + i);
                c.place(f, bricks, 3 + i, 1, 3);
                c.place(f, bricks, 3 + i, 1, 7);
            }
            for y in 1..=3 {
                c.place(f, bricks, 5, y, 5);
            }
            let water = c.state("water")?;
            c.place(f, water, 5, 4, 5);
        }
        2 => {
            let cobble = c.state("cobblestone")?;
            for z in 1..=9 {
                c.place(f, cobble, 1, 3, z);
                c.place(f, cobble, 9, 3, z);
            }
            for x in 1..=9 {
                c.place(f, cobble, x, 3, 1);
                c.place(f, cobble, x, 3, 9);
            }
            for (x, y, z) in [
                (5, 1, 4),
                (5, 1, 6),
                (5, 3, 4),
                (5, 3, 6),
                (4, 1, 5),
                (6, 1, 5),
                (4, 3, 5),
                (6, 3, 5),
            ] {
                c.place(f, cobble, x, y, z);
            }
            for y in 1..=3 {
                c.place(f, cobble, 4, y, 4);
                c.place(f, cobble, 6, y, 4);
                c.place(f, cobble, 4, y, 6);
                c.place(f, cobble, 6, y, 6);
            }
            let wall_torch = c.state("wall_torch")?;
            c.place(f, wall_torch, 5, 3, 5);
            let planks = c.state("oak_planks")?;
            for z in 2..=8 {
                c.place(f, planks, 2, 3, z);
                c.place(f, planks, 3, 3, z);
                if z <= 3 || z >= 7 {
                    c.place(f, planks, 4, 3, z);
                    c.place(f, planks, 5, 3, z);
                    c.place(f, planks, 6, 3, z);
                }
                c.place(f, planks, 7, 3, z);
                c.place(f, planks, 8, 3, z);
            }
            let ladder = c.state("ladder[facing=west]")?;
            for y in 1..=3 {
                c.place(f, ladder, 9, y, 3);
            }
            c.create_chest_at(f, 3, 4, 8, CROSSING_LOOT)?;
        }
        _ => {}
    }
    Ok(())
}
