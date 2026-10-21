//! Woodland mansions (VMC-025e5, `WoodlandMansionStructure`,
//! `WoodlandMansionPieces`): a grid of corridors and rooms on three floors
//! (`MansionGrid`), then template pieces for the entrance, outer walls,
//! roofs, corridor floors, inner walls and rooms (`MansionPiecePlacer`).

use super::super::random::Random;
use super::super::template::{Mirror, Rotation, ROTATIONS};
use super::piece::{rotated, Direction, Piece, PieceKind, TemplateKind, TemplatePiece};
use super::templated::template_box;
use super::GenContext;

const CORRIDOR: i32 = 1;
const ROOM: i32 = 2;
const START_ROOM: i32 = 3;
const BLOCKED: i32 = 5;
const ROOM_1X1: i32 = 65536;
const ROOM_1X2: i32 = 131072;
const ROOM_2X2: i32 = 262144;
const ORIGIN_FLAG: i32 = 1048576;
const DOOR_FLAG: i32 = 2097152;
const STAIRS_FLAG: i32 = 4194304;
const CORRIDOR_FLAG: i32 = 8388608;
const TYPE_MASK: i32 = 983040;
const ID_MASK: i32 = 65535;

fn step(d: Direction) -> (i32, i32) {
    match d {
        Direction::North => (0, -1),
        Direction::South => (0, 1),
        Direction::West => (-1, 0),
        Direction::East => (1, 0),
    }
}

/// `Direction.from2DDataValue`.
fn from_2d(value: i32) -> Direction {
    match value & 3 {
        0 => Direction::South,
        1 => Direction::West,
        2 => Direction::North,
        _ => Direction::East,
    }
}

/// `Rotation.rotate(Direction)`.
fn rotate(rotation: Rotation, d: Direction) -> Direction {
    match rotation {
        Rotation::None => d,
        Rotation::Clockwise90 => d.clockwise(),
        Rotation::Clockwise180 => d.opposite(),
        Rotation::Counterclockwise90 => d.counter_clockwise(),
    }
}

/// `SimpleGrid`.
#[derive(Clone)]
struct Grid {
    cells: Vec<i32>,
    width: i32,
    height: i32,
    outside: i32,
}

impl Grid {
    fn new(width: i32, height: i32, outside: i32) -> Grid {
        Grid {
            cells: vec![0; (width * height) as usize],
            width,
            height,
            outside,
        }
    }

    fn set(&mut self, x: i32, y: i32, value: i32) {
        if x >= 0 && x < self.width && y >= 0 && y < self.height {
            self.cells[(x * self.height + y) as usize] = value;
        }
    }

    fn fill(&mut self, x0: i32, y0: i32, x1: i32, y1: i32, value: i32) {
        for y in y0..=y1 {
            for x in x0..=x1 {
                self.set(x, y, value);
            }
        }
    }

    fn get(&self, x: i32, y: i32) -> i32 {
        if x >= 0 && x < self.width && y >= 0 && y < self.height {
            self.cells[(x * self.height + y) as usize]
        } else {
            self.outside
        }
    }

    fn set_if(&mut self, x: i32, y: i32, if_value: i32, value: i32) {
        if self.get(x, y) == if_value {
            self.set(x, y, value);
        }
    }

    fn edges_to(&self, x: i32, y: i32, value: i32) -> bool {
        self.get(x - 1, y) == value
            || self.get(x + 1, y) == value
            || self.get(x, y + 1) == value
            || self.get(x, y - 1) == value
    }

    /// `MansionGrid.isHouse`.
    fn is_house(&self, x: i32, y: i32) -> bool {
        matches!(self.get(x, y), 1..=4)
    }
}

/// `MansionGrid`.
struct MansionGrid {
    base: Grid,
    third: Grid,
    rooms: [Grid; 3],
    entrance: (i32, i32),
}

impl MansionGrid {
    fn new(random: &mut Random) -> MansionGrid {
        let (ex, ey) = (7, 4);
        let mut base = Grid::new(11, 11, BLOCKED);
        base.fill(ex, ey, ex + 1, ey + 1, START_ROOM);
        base.fill(ex - 1, ey, ex - 1, ey + 1, ROOM);
        base.fill(ex + 2, ey - 2, ex + 3, ey + 3, BLOCKED);
        base.fill(ex + 1, ey - 2, ex + 1, ey - 1, CORRIDOR);
        base.fill(ex + 1, ey + 2, ex + 1, ey + 3, CORRIDOR);
        base.set(ex - 1, ey - 1, CORRIDOR);
        base.set(ex - 1, ey + 2, CORRIDOR);
        base.fill(0, 0, 11, 1, BLOCKED);
        base.fill(0, 9, 11, 11, BLOCKED);
        corridor(random, &mut base, ex, ey - 2, Direction::West, 6);
        corridor(random, &mut base, ex, ey + 3, Direction::West, 6);
        corridor(random, &mut base, ex - 2, ey - 1, Direction::West, 3);
        corridor(random, &mut base, ex - 2, ey + 2, Direction::West, 3);
        while clean_edges(&mut base) {}
        let mut grid = MansionGrid {
            third: Grid::new(11, 11, BLOCKED),
            rooms: [
                Grid::new(11, 11, BLOCKED),
                Grid::new(11, 11, BLOCKED),
                Grid::new(11, 11, BLOCKED),
            ],
            base,
            entrance: (ex, ey),
        };
        let base = grid.base.clone();
        identify_rooms(random, &base, &mut grid.rooms[0]);
        identify_rooms(random, &base, &mut grid.rooms[1]);
        grid.rooms[0].fill(ex + 1, ey, ex + 1, ey + 1, CORRIDOR_FLAG);
        grid.rooms[1].fill(ex + 1, ey, ex + 1, ey + 1, CORRIDOR_FLAG);
        grid.setup_third_floor(random);
        let third = grid.third.clone();
        identify_rooms(random, &third, &mut grid.rooms[2]);
        grid
    }

    fn is_room_id(&self, x: i32, y: i32, floor: usize, room: i32) -> bool {
        (self.rooms[floor].get(x, y) & ID_MASK) == room
    }

    /// `get1x2RoomDirection`.
    fn room_direction(&self, x: i32, y: i32, floor: usize, room: i32) -> Option<Direction> {
        Direction::HORIZONTAL.into_iter().find(|&d| {
            let (dx, dz) = step(d);
            self.is_room_id(x + dx, y + dz, floor, room)
        })
    }

    fn setup_third_floor(&mut self, random: &mut Random) {
        let mut potential = Vec::new();
        for y in 0..self.third.height {
            for x in 0..self.third.width {
                let data = self.rooms[1].get(x, y);
                if data & TYPE_MASK == ROOM_1X2 && data & DOOR_FLAG == DOOR_FLAG {
                    potential.push((x, y));
                }
            }
        }
        let (w, h) = (self.third.width, self.third.height);
        if potential.is_empty() {
            self.third.fill(0, 0, w, h, BLOCKED);
            return;
        }
        let (rx, ry) = potential[random.next_int_bounded(potential.len() as i32) as usize];
        let data = self.rooms[1].get(rx, ry);
        self.rooms[1].set(rx, ry, data | STAIRS_FLAG);
        let dir = self
            .room_direction(rx, ry, 1, data & ID_MASK)
            .expect("a two-cell room has its other cell beside it");
        let (dx, dz) = step(dir);
        let (end_x, end_y) = (rx + dx, ry + dz);
        for y in 0..h {
            for x in 0..w {
                if !self.base.is_house(x, y) {
                    self.third.set(x, y, BLOCKED);
                } else if x == rx && y == ry {
                    self.third.set(x, y, START_ROOM);
                } else if x == end_x && y == end_y {
                    self.third.set(x, y, START_ROOM);
                    self.rooms[2].set(x, y, CORRIDOR_FLAG);
                }
            }
        }
        let corridors: Vec<Direction> = Direction::HORIZONTAL
            .into_iter()
            .filter(|&d| {
                let (dx, dz) = step(d);
                self.third.get(end_x + dx, end_y + dz) == 0
            })
            .collect();
        if corridors.is_empty() {
            self.third.fill(0, 0, w, h, BLOCKED);
            self.rooms[1].set(rx, ry, data);
        } else {
            let dir = corridors[random.next_int_bounded(corridors.len() as i32) as usize];
            let (dx, dz) = step(dir);
            corridor(random, &mut self.third, end_x + dx, end_y + dz, dir, 4);
            while clean_edges(&mut self.third) {}
        }
    }
}

/// `MansionGrid.recursiveCorridor`.
fn corridor(random: &mut Random, grid: &mut Grid, x: i32, y: i32, heading: Direction, depth: i32) {
    if depth <= 0 {
        return;
    }
    let (hx, hz) = step(heading);
    grid.set(x, y, CORRIDOR);
    grid.set_if(x + hx, y + hz, 0, CORRIDOR);
    for _ in 0..8 {
        let next = from_2d(random.next_int_bounded(4));
        if next != heading.opposite() && (next != Direction::East || !random.next_bool()) {
            let (nx, ny) = (x + hx, y + hz);
            let (sx, sz) = step(next);
            if grid.get(nx + sx, ny + sz) == 0 && grid.get(nx + sx * 2, ny + sz * 2) == 0 {
                corridor(random, grid, x + hx + sx, y + hz + sz, next, depth - 1);
                break;
            }
        }
    }
    let (cx, cz) = step(heading.clockwise());
    let (ccx, ccz) = step(heading.counter_clockwise());
    grid.set_if(x + cx, y + cz, 0, ROOM);
    grid.set_if(x + ccx, y + ccz, 0, ROOM);
    grid.set_if(x + hx + cx, y + hz + cz, 0, ROOM);
    grid.set_if(x + hx + ccx, y + hz + ccz, 0, ROOM);
    grid.set_if(x + hx * 2, y + hz * 2, 0, ROOM);
    grid.set_if(x + cx * 2, y + cz * 2, 0, ROOM);
    grid.set_if(x + ccx * 2, y + ccz * 2, 0, ROOM);
}

/// `MansionGrid.cleanEdges`.
fn clean_edges(grid: &mut Grid) -> bool {
    let mut touched = false;
    for y in 0..grid.height {
        for x in 0..grid.width {
            if grid.get(x, y) != 0 {
                continue;
            }
            let house = |g: &Grid, dx: i32, dy: i32| g.is_house(x + dx, y + dy) as i32;
            let direct =
                house(grid, 1, 0) + house(grid, -1, 0) + house(grid, 0, 1) + house(grid, 0, -1);
            if direct >= 3 {
                grid.set(x, y, ROOM);
                touched = true;
            } else if direct == 2 {
                let diagonal = house(grid, 1, 1)
                    + house(grid, -1, 1)
                    + house(grid, 1, -1)
                    + house(grid, -1, -1);
                if diagonal <= 1 {
                    grid.set(x, y, ROOM);
                    touched = true;
                }
            }
        }
    }
    touched
}

/// `MansionGrid.identifyRooms`.
fn identify_rooms(random: &mut Random, from: &Grid, rooms: &mut Grid) {
    let mut positions = Vec::new();
    for y in 0..from.height {
        for x in 0..from.width {
            if from.get(x, y) == ROOM {
                positions.push((x, y));
            }
        }
    }
    for i in (2..=positions.len()).rev() {
        let swap_to = random.next_int_bounded(i as i32) as usize;
        positions.swap(i - 1, swap_to);
    }
    let mut room_id = 10;
    for (x, y) in positions {
        if rooms.get(x, y) != 0 {
            continue;
        }
        let (mut x0, mut x1, mut y0, mut y1) = (x, x, y, y);
        let mut kind = ROOM_1X1;
        let free = |rooms: &Grid, dx: i32, dy: i32| {
            rooms.get(x + dx, y + dy) == 0 && from.get(x + dx, y + dy) == ROOM
        };
        if free(rooms, 1, 0) && free(rooms, 0, 1) && free(rooms, 1, 1) {
            x1 += 1;
            y1 += 1;
            kind = ROOM_2X2;
        } else if free(rooms, -1, 0) && free(rooms, 0, 1) && free(rooms, -1, 1) {
            x0 -= 1;
            y1 += 1;
            kind = ROOM_2X2;
        } else if free(rooms, -1, 0) && free(rooms, 0, -1) && free(rooms, -1, -1) {
            x0 -= 1;
            y0 -= 1;
            kind = ROOM_2X2;
        } else if free(rooms, 1, 0) {
            x1 += 1;
            kind = ROOM_1X2;
        } else if free(rooms, 0, 1) {
            y1 += 1;
            kind = ROOM_1X2;
        } else if free(rooms, -1, 0) {
            x0 -= 1;
            kind = ROOM_1X2;
        } else if free(rooms, 0, -1) {
            y0 -= 1;
            kind = ROOM_1X2;
        }
        let mut door_x = if random.next_bool() { x0 } else { x1 };
        let mut door_y = if random.next_bool() { y0 } else { y1 };
        let mut door_flag = DOOR_FLAG;
        if !from.edges_to(door_x, door_y, CORRIDOR) {
            door_x = if door_x == x0 { x1 } else { x0 };
            door_y = if door_y == y0 { y1 } else { y0 };
            if !from.edges_to(door_x, door_y, CORRIDOR) {
                door_y = if door_y == y0 { y1 } else { y0 };
                if !from.edges_to(door_x, door_y, CORRIDOR) {
                    door_x = if door_x == x0 { x1 } else { x0 };
                    door_y = if door_y == y0 { y1 } else { y0 };
                    if !from.edges_to(door_x, door_y, CORRIDOR) {
                        door_flag = 0;
                        door_x = x0;
                        door_y = y0;
                    }
                }
            }
        }
        for ry in y0..=y1 {
            for rx in x0..=x1 {
                if rx == door_x && ry == door_y {
                    rooms.set(rx, ry, ORIGIN_FLAG | door_flag | kind | room_id);
                } else {
                    rooms.set(rx, ry, kind | room_id);
                }
            }
        }
        room_id += 1;
    }
}

/// A room's door: towards a side, or up (none on a side).
#[derive(Clone, Copy, PartialEq, Eq)]
enum Door {
    Side(Direction),
    Up,
}

/// The room templates of a floor (`FloorRoomCollection`).
fn room_1x1(random: &mut Random, floor: usize) -> String {
    let letter = if floor == 0 { "a" } else { "b" };
    format!("1x1_{letter}{}", random.next_int_bounded(5) + 1)
}

fn room_1x1_secret(random: &mut Random) -> String {
    format!("1x1_as{}", random.next_int_bounded(4) + 1)
}

fn room_1x2_side(random: &mut Random, floor: usize, stairs: bool) -> String {
    if floor == 0 {
        format!("1x2_a{}", random.next_int_bounded(9) + 1)
    } else if stairs {
        "1x2_c_stairs".to_string()
    } else {
        format!("1x2_c{}", random.next_int_bounded(4) + 1)
    }
}

fn room_1x2_front(random: &mut Random, floor: usize, stairs: bool) -> String {
    if floor == 0 {
        format!("1x2_b{}", random.next_int_bounded(5) + 1)
    } else if stairs {
        "1x2_d_stairs".to_string()
    } else {
        format!("1x2_d{}", random.next_int_bounded(5) + 1)
    }
}

fn room_1x2_secret(random: &mut Random, floor: usize) -> String {
    if floor == 0 {
        format!("1x2_s{}", random.next_int_bounded(2) + 1)
    } else {
        format!("1x2_se{}", random.next_int_bounded(1) + 1)
    }
}

fn room_2x2(random: &mut Random, floor: usize) -> String {
    if floor == 0 {
        format!("2x2_a{}", random.next_int_bounded(4) + 1)
    } else {
        format!("2x2_b{}", random.next_int_bounded(5) + 1)
    }
}

type Pos = [i32; 3];

fn relative(p: Pos, d: Direction, n: i32) -> Pos {
    let (dx, dz) = step(d);
    [p[0] + dx * n, p[1], p[2] + dz * n]
}

fn above(p: Pos, n: i32) -> Pos {
    [p[0], p[1] + n, p[2]]
}

/// `BlockPos.rotate`.
fn rotate_pos(p: Pos, rotation: Rotation) -> Pos {
    match rotation {
        Rotation::None => p,
        Rotation::Clockwise90 => [-p[2], p[1], p[0]],
        Rotation::Clockwise180 => [-p[0], p[1], -p[2]],
        Rotation::Counterclockwise90 => [p[2], p[1], -p[0]],
    }
}

/// `PlacementData`.
struct Placement {
    rotation: Rotation,
    position: Pos,
    wall: &'static str,
}

struct Placer<'a, 'b> {
    gc: &'a mut GenContext<'b>,
    pieces: Vec<Piece>,
    start: (i32, i32),
}

impl Placer<'_, '_> {
    fn add(
        &mut self,
        name: &str,
        position: Pos,
        rotation: Rotation,
        mirror: Mirror,
    ) -> Result<(), String> {
        let size = self
            .gc
            .env
            .registry
            .template(&format!("minecraft:woodland_mansion/{name}"))?
            .size;
        self.pieces.push(Piece {
            kind: PieceKind::Template(TemplatePiece {
                kind: TemplateKind::Mansion,
                name: name.to_string(),
                position,
                rotation,
                mirror,
            }),
            bbox: template_box(size, position, rotation, [0, 0, 0], mirror),
            orientation: Some(Direction::North),
            gen_depth: 0,
        });
        Ok(())
    }

    fn wall_piece(&mut self, data: &mut Placement) -> Result<(), String> {
        let pos = relative(data.position, rotate(data.rotation, Direction::East), 7);
        self.add(data.wall, pos, data.rotation, Mirror::None)?;
        data.position = relative(data.position, rotate(data.rotation, Direction::South), 8);
        Ok(())
    }

    fn turn(&mut self, data: &mut Placement) -> Result<(), String> {
        data.position = relative(data.position, rotate(data.rotation, Direction::South), -1);
        self.add("wall_corner", data.position, data.rotation, Mirror::None)?;
        data.position = relative(data.position, rotate(data.rotation, Direction::South), -7);
        data.position = relative(data.position, rotate(data.rotation, Direction::West), -6);
        data.rotation = rotated(data.rotation, Rotation::Clockwise90);
        Ok(())
    }

    fn inner_turn(&mut self, data: &mut Placement) {
        data.position = relative(data.position, rotate(data.rotation, Direction::South), 6);
        data.position = relative(data.position, rotate(data.rotation, Direction::East), 8);
        data.rotation = rotated(data.rotation, Rotation::Counterclockwise90);
    }

    /// `traverseOuterWalls`.
    #[allow(clippy::too_many_arguments)]
    fn outer_walls(
        &mut self,
        data: &mut Placement,
        grid: &Grid,
        mut direction: Direction,
        (start_x, start_y): (i32, i32),
        (end_x, end_y): (i32, i32),
    ) -> Result<(), String> {
        let (mut x, mut y) = (start_x, start_y);
        let start_direction = direction;
        loop {
            let (dx, dz) = step(direction);
            let (cx, cz) = step(direction.counter_clockwise());
            if !grid.is_house(x + dx, y + dz) {
                self.turn(data)?;
                direction = direction.clockwise();
                if x != end_x || y != end_y || start_direction != direction {
                    self.wall_piece(data)?;
                }
            } else if grid.is_house(x + dx + cx, y + dz + cz) {
                self.inner_turn(data);
                x += dx;
                y += dz;
                direction = direction.counter_clockwise();
            } else {
                x += dx;
                y += dz;
                if x != end_x || y != end_y || start_direction != direction {
                    self.wall_piece(data)?;
                }
            }
            if x == end_x && y == end_y && start_direction == direction {
                return Ok(());
            }
        }
    }

    fn cell(&self, origin: Pos, rotation: Rotation, x: i32, y: i32, east_extra: i32) -> Pos {
        let p = relative(
            origin,
            rotate(rotation, Direction::South),
            8 + (y - self.start.1) * 8,
        );
        relative(
            p,
            rotate(rotation, Direction::East),
            east_extra + (x - self.start.0) * 8,
        )
    }

    /// `createRoof`.
    fn roof(
        &mut self,
        origin: Pos,
        rotation: Rotation,
        grid: &Grid,
        above_grid: Option<&Grid>,
    ) -> Result<(), String> {
        let r = |d: Direction| rotate(rotation, d);
        let turned = |by: Rotation| rotated(rotation, by);
        for y in 0..grid.height {
            for x in 0..grid.width {
                let p = self.cell(origin, rotation, x, y, 0);
                let is_above = above_grid.is_some_and(|a| a.is_house(x, y));
                if grid.is_house(x, y) && !is_above {
                    self.add("roof", above(p, 3), rotation, Mirror::None)?;
                    if !grid.is_house(x + 1, y) {
                        self.add(
                            "roof_front",
                            relative(p, r(Direction::East), 6),
                            rotation,
                            Mirror::None,
                        )?;
                    }
                    if !grid.is_house(x - 1, y) {
                        let p2 =
                            relative(relative(p, r(Direction::East), 0), r(Direction::South), 7);
                        self.add(
                            "roof_front",
                            p2,
                            turned(Rotation::Clockwise180),
                            Mirror::None,
                        )?;
                    }
                    if !grid.is_house(x, y - 1) {
                        let p2 = relative(p, r(Direction::West), 1);
                        self.add(
                            "roof_front",
                            p2,
                            turned(Rotation::Counterclockwise90),
                            Mirror::None,
                        )?;
                    }
                    if !grid.is_house(x, y + 1) {
                        let p2 =
                            relative(relative(p, r(Direction::East), 6), r(Direction::South), 6);
                        self.add(
                            "roof_front",
                            p2,
                            turned(Rotation::Clockwise90),
                            Mirror::None,
                        )?;
                    }
                }
            }
        }
        if let Some(above_grid) = above_grid {
            for y in 0..grid.height {
                for x in 0..grid.width {
                    let p = self.cell(origin, rotation, x, y, 0);
                    if !(grid.is_house(x, y) && above_grid.is_house(x, y)) {
                        continue;
                    }
                    if !grid.is_house(x + 1, y) {
                        self.add(
                            "small_wall",
                            relative(p, r(Direction::East), 7),
                            rotation,
                            Mirror::None,
                        )?;
                    }
                    if !grid.is_house(x - 1, y) {
                        let p2 =
                            relative(relative(p, r(Direction::West), 1), r(Direction::South), 6);
                        self.add(
                            "small_wall",
                            p2,
                            turned(Rotation::Clockwise180),
                            Mirror::None,
                        )?;
                    }
                    if !grid.is_house(x, y - 1) {
                        let p2 =
                            relative(relative(p, r(Direction::West), 0), r(Direction::North), 1);
                        self.add(
                            "small_wall",
                            p2,
                            turned(Rotation::Counterclockwise90),
                            Mirror::None,
                        )?;
                    }
                    if !grid.is_house(x, y + 1) {
                        let p2 =
                            relative(relative(p, r(Direction::East), 6), r(Direction::South), 7);
                        self.add(
                            "small_wall",
                            p2,
                            turned(Rotation::Clockwise90),
                            Mirror::None,
                        )?;
                    }
                    if !grid.is_house(x + 1, y) {
                        if !grid.is_house(x, y - 1) {
                            let p2 = relative(
                                relative(p, r(Direction::East), 7),
                                r(Direction::North),
                                2,
                            );
                            self.add("small_wall_corner", p2, rotation, Mirror::None)?;
                        }
                        if !grid.is_house(x, y + 1) {
                            let p2 = relative(
                                relative(p, r(Direction::East), 8),
                                r(Direction::South),
                                7,
                            );
                            self.add(
                                "small_wall_corner",
                                p2,
                                turned(Rotation::Clockwise90),
                                Mirror::None,
                            )?;
                        }
                    }
                    if !grid.is_house(x - 1, y) {
                        if !grid.is_house(x, y - 1) {
                            let p2 = relative(
                                relative(p, r(Direction::West), 2),
                                r(Direction::North),
                                1,
                            );
                            self.add(
                                "small_wall_corner",
                                p2,
                                turned(Rotation::Counterclockwise90),
                                Mirror::None,
                            )?;
                        }
                        if !grid.is_house(x, y + 1) {
                            let p2 = relative(
                                relative(p, r(Direction::West), 1),
                                r(Direction::South),
                                8,
                            );
                            self.add(
                                "small_wall_corner",
                                p2,
                                turned(Rotation::Clockwise180),
                                Mirror::None,
                            )?;
                        }
                    }
                }
            }
        }
        for y in 0..grid.height {
            for x in 0..grid.width {
                let p = self.cell(origin, rotation, x, y, 0);
                let is_above = above_grid.is_some_and(|a| a.is_house(x, y));
                if !grid.is_house(x, y) || is_above {
                    continue;
                }
                if !grid.is_house(x + 1, y) {
                    let p2 = relative(p, r(Direction::East), 6);
                    if !grid.is_house(x, y + 1) {
                        self.add(
                            "roof_corner",
                            relative(p2, r(Direction::South), 6),
                            rotation,
                            Mirror::None,
                        )?;
                    } else if grid.is_house(x + 1, y + 1) {
                        self.add(
                            "roof_inner_corner",
                            relative(p2, r(Direction::South), 5),
                            rotation,
                            Mirror::None,
                        )?;
                    }
                    if !grid.is_house(x, y - 1) {
                        self.add(
                            "roof_corner",
                            p2,
                            turned(Rotation::Counterclockwise90),
                            Mirror::None,
                        )?;
                    } else if grid.is_house(x + 1, y - 1) {
                        let p3 =
                            relative(relative(p, r(Direction::East), 9), r(Direction::North), 2);
                        self.add(
                            "roof_inner_corner",
                            p3,
                            turned(Rotation::Clockwise90),
                            Mirror::None,
                        )?;
                    }
                }
                if !grid.is_house(x - 1, y) {
                    let p2 = relative(relative(p, r(Direction::East), 0), r(Direction::South), 0);
                    if !grid.is_house(x, y + 1) {
                        let p3 = relative(p2, r(Direction::South), 6);
                        self.add(
                            "roof_corner",
                            p3,
                            turned(Rotation::Clockwise90),
                            Mirror::None,
                        )?;
                    } else if grid.is_house(x - 1, y + 1) {
                        let p3 =
                            relative(relative(p2, r(Direction::South), 8), r(Direction::West), 3);
                        self.add(
                            "roof_inner_corner",
                            p3,
                            turned(Rotation::Counterclockwise90),
                            Mirror::None,
                        )?;
                    }
                    if !grid.is_house(x, y - 1) {
                        self.add(
                            "roof_corner",
                            p2,
                            turned(Rotation::Clockwise180),
                            Mirror::None,
                        )?;
                    } else if grid.is_house(x - 1, y - 1) {
                        let p3 = relative(p2, r(Direction::South), 1);
                        self.add(
                            "roof_inner_corner",
                            p3,
                            turned(Rotation::Clockwise180),
                            Mirror::None,
                        )?;
                    }
                }
            }
        }
        Ok(())
    }

    fn room_1x1(
        &mut self,
        room_pos: Pos,
        rotation: Rotation,
        door: Option<Door>,
        floor: usize,
    ) -> Result<(), String> {
        let mut piece_rot = Rotation::None;
        let mut name = room_1x1(&mut self.gc.random, floor);
        if door != Some(Door::Side(Direction::East)) {
            match door {
                Some(Door::Side(Direction::North)) => {
                    piece_rot = rotated(piece_rot, Rotation::Counterclockwise90)
                }
                Some(Door::Side(Direction::West)) => {
                    piece_rot = rotated(piece_rot, Rotation::Clockwise180)
                }
                Some(Door::Side(Direction::South)) => {
                    piece_rot = rotated(piece_rot, Rotation::Clockwise90)
                }
                _ => name = room_1x1_secret(&mut self.gc.random),
            }
        }
        // `getZeroPositionWithTransform((1, 0, 0), NONE, pieceRot, 7, 7)`.
        let zero = match piece_rot {
            Rotation::Counterclockwise90 => [1, 0, 6],
            Rotation::Clockwise90 => [7, 0, 0],
            Rotation::Clockwise180 => [7, 0, 6],
            Rotation::None => [1, 0, 0],
        };
        let piece_rot = rotated(piece_rot, rotation);
        let o = rotate_pos(zero, rotation);
        let pos = [room_pos[0] + o[0], room_pos[1], room_pos[2] + o[2]];
        self.add(&name, pos, piece_rot, Mirror::None)
    }

    #[allow(clippy::too_many_arguments)]
    fn room_1x2(
        &mut self,
        room_pos: Pos,
        rotation: Rotation,
        room_dir: Option<Direction>,
        door: Door,
        floor: usize,
        stairs: bool,
    ) -> Result<(), String> {
        use Direction::*;
        let r = |d: Direction| rotate(rotation, d);
        let turned = |by: Rotation| rotated(rotation, by);
        let rnd = &mut self.gc.random;
        let (name, pos, rot, mirror) = match (door, room_dir) {
            (Door::Side(East), Some(South)) => (
                room_1x2_side(rnd, floor, stairs),
                relative(room_pos, r(East), 1),
                rotation,
                Mirror::None,
            ),
            (Door::Side(East), Some(North)) => (
                room_1x2_side(rnd, floor, stairs),
                relative(relative(room_pos, r(East), 1), r(South), 6),
                rotation,
                Mirror::LeftRight,
            ),
            (Door::Side(West), Some(North)) => (
                room_1x2_side(rnd, floor, stairs),
                relative(relative(room_pos, r(East), 7), r(South), 6),
                turned(Rotation::Clockwise180),
                Mirror::None,
            ),
            (Door::Side(West), Some(South)) => (
                room_1x2_side(rnd, floor, stairs),
                relative(room_pos, r(East), 7),
                rotation,
                Mirror::FrontBack,
            ),
            (Door::Side(South), Some(East)) => (
                room_1x2_side(rnd, floor, stairs),
                relative(room_pos, r(East), 1),
                turned(Rotation::Clockwise90),
                Mirror::LeftRight,
            ),
            (Door::Side(South), Some(West)) => (
                room_1x2_side(rnd, floor, stairs),
                relative(room_pos, r(East), 7),
                turned(Rotation::Clockwise90),
                Mirror::None,
            ),
            (Door::Side(North), Some(West)) => (
                room_1x2_side(rnd, floor, stairs),
                relative(relative(room_pos, r(East), 7), r(South), 6),
                turned(Rotation::Clockwise90),
                Mirror::FrontBack,
            ),
            (Door::Side(North), Some(East)) => (
                room_1x2_side(rnd, floor, stairs),
                relative(relative(room_pos, r(East), 1), r(South), 6),
                turned(Rotation::Counterclockwise90),
                Mirror::None,
            ),
            (Door::Side(South), Some(North)) => (
                room_1x2_front(rnd, floor, stairs),
                relative(relative(room_pos, r(East), 1), r(North), 8),
                rotation,
                Mirror::None,
            ),
            (Door::Side(North), Some(South)) => (
                room_1x2_front(rnd, floor, stairs),
                relative(relative(room_pos, r(East), 7), r(South), 14),
                turned(Rotation::Clockwise180),
                Mirror::None,
            ),
            (Door::Side(West), Some(East)) => (
                room_1x2_front(rnd, floor, stairs),
                relative(room_pos, r(East), 15),
                turned(Rotation::Clockwise90),
                Mirror::None,
            ),
            (Door::Side(East), Some(West)) => (
                room_1x2_front(rnd, floor, stairs),
                relative(relative(room_pos, r(West), 7), r(South), 6),
                turned(Rotation::Counterclockwise90),
                Mirror::None,
            ),
            (Door::Up, Some(East)) => (
                room_1x2_secret(rnd, floor),
                relative(room_pos, r(East), 15),
                turned(Rotation::Clockwise90),
                Mirror::None,
            ),
            (Door::Up, Some(South)) => (
                room_1x2_secret(rnd, floor),
                relative(relative(room_pos, r(East), 1), r(North), 0),
                rotation,
                Mirror::None,
            ),
            _ => return Ok(()),
        };
        self.add(&name, pos, rot, mirror)
    }

    fn room_2x2(
        &mut self,
        room_pos: Pos,
        rotation: Rotation,
        room_dir: Direction,
        door: Direction,
        floor: usize,
    ) -> Result<(), String> {
        use Direction::*;
        let (mut east, mut south, mut rot, mut mirror) = (0, 0, rotation, Mirror::None);
        match (door, room_dir) {
            (East, South) => east = -7,
            (East, North) => {
                east = -7;
                south = 6;
                mirror = Mirror::LeftRight;
            }
            (North, East) => {
                east = 1;
                south = 14;
                rot = rotated(rotation, Rotation::Counterclockwise90);
            }
            (North, West) => {
                east = 7;
                south = 14;
                rot = rotated(rotation, Rotation::Counterclockwise90);
                mirror = Mirror::LeftRight;
            }
            (South, West) => {
                east = 7;
                south = -8;
                rot = rotated(rotation, Rotation::Clockwise90);
            }
            (South, East) => {
                east = 1;
                south = -8;
                rot = rotated(rotation, Rotation::Clockwise90);
                mirror = Mirror::LeftRight;
            }
            (West, North) => {
                east = 15;
                south = 6;
                rot = rotated(rotation, Rotation::Clockwise180);
            }
            (West, South) => {
                east = 15;
                mirror = Mirror::FrontBack;
            }
            _ => {}
        }
        let pos = relative(
            relative(room_pos, rotate(rotation, East), east),
            rotate(rotation, South),
            south,
        );
        let name = room_2x2(&mut self.gc.random, floor);
        self.add(&name, pos, rot, mirror)
    }

    /// `createMansion`.
    fn create(
        &mut self,
        origin: Pos,
        rotation: Rotation,
        mansion: &MansionGrid,
    ) -> Result<(), String> {
        let mut data = Placement {
            rotation,
            position: origin,
            wall: "wall_flat",
        };
        // `entrance`.
        let west = rotate(data.rotation, Direction::West);
        self.add(
            "entrance",
            relative(data.position, west, 9),
            data.rotation,
            Mirror::None,
        )?;
        data.position = relative(data.position, rotate(data.rotation, Direction::South), 16);
        let mut second = Placement {
            rotation: data.rotation,
            position: above(data.position, 8),
            wall: "wall_window",
        };
        let base = &mansion.base;
        let third = &mansion.third;
        self.start = (mansion.entrance.0 + 1, mansion.entrance.1 + 1);
        let end = (mansion.entrance.0 + 1, mansion.entrance.1);
        self.outer_walls(&mut data, base, Direction::South, self.start, end)?;
        self.outer_walls(&mut second, base, Direction::South, self.start, end)?;
        let mut third_data = Placement {
            rotation: data.rotation,
            position: above(data.position, 19),
            wall: "wall_window",
        };
        'third: for y in 0..third.height {
            for x in (0..third.width).rev() {
                if third.is_house(x, y) {
                    third_data.position = relative(
                        third_data.position,
                        rotate(rotation, Direction::South),
                        8 + (y - self.start.1) * 8,
                    );
                    third_data.position = relative(
                        third_data.position,
                        rotate(rotation, Direction::East),
                        (x - self.start.0) * 8,
                    );
                    self.wall_piece(&mut third_data)?;
                    self.outer_walls(&mut third_data, third, Direction::South, (x, y), (x, y))?;
                    break 'third;
                }
            }
        }
        self.roof(above(origin, 16), rotation, base, Some(third))?;
        self.roof(above(origin, 27), rotation, third, None)?;
        for floor in 0..3 {
            let floor_origin = above(origin, 8 * floor as i32 + if floor == 2 { 3 } else { 0 });
            let rooms = &mansion.rooms[floor];
            let grid = if floor == 2 { third } else { base };
            let south_piece = if floor == 0 {
                "carpet_south_1"
            } else {
                "carpet_south_2"
            };
            let west_piece = if floor == 0 {
                "carpet_west_1"
            } else {
                "carpet_west_2"
            };
            let r = |d: Direction| rotate(rotation, d);
            for y in 0..grid.height {
                for x in 0..grid.width {
                    if grid.get(x, y) != CORRIDOR {
                        continue;
                    }
                    let pos = self.cell(floor_origin, rotation, x, y, 0);
                    self.add("corridor_floor", pos, rotation, Mirror::None)?;
                    let joins = |dx: i32, dy: i32| {
                        grid.get(x + dx, y + dy) == CORRIDOR
                            || rooms.get(x + dx, y + dy) & CORRIDOR_FLAG == CORRIDOR_FLAG
                    };
                    if joins(0, -1) {
                        self.add(
                            "carpet_north",
                            above(relative(pos, r(Direction::East), 1), 1),
                            rotation,
                            Mirror::None,
                        )?;
                    }
                    if joins(1, 0) {
                        let p = above(
                            relative(relative(pos, r(Direction::South), 1), r(Direction::East), 5),
                            1,
                        );
                        self.add("carpet_east", p, rotation, Mirror::None)?;
                    }
                    if joins(0, 1) {
                        let p =
                            relative(relative(pos, r(Direction::South), 5), r(Direction::West), 1);
                        self.add(south_piece, p, rotation, Mirror::None)?;
                    }
                    if joins(-1, 0) {
                        let p =
                            relative(relative(pos, r(Direction::West), 1), r(Direction::North), 1);
                        self.add(west_piece, p, rotation, Mirror::None)?;
                    }
                }
            }
            let wall_piece = if floor == 0 {
                "indoors_wall_1"
            } else {
                "indoors_wall_2"
            };
            let door_piece = if floor == 0 {
                "indoors_door_1"
            } else {
                "indoors_door_2"
            };
            for y in 0..grid.height {
                for x in 0..grid.width {
                    let mut third_start = floor == 2 && grid.get(x, y) == START_ROOM;
                    if !(grid.get(x, y) == ROOM || third_start) {
                        continue;
                    }
                    let data = rooms.get(x, y);
                    let kind = data & TYPE_MASK;
                    let room_id = data & ID_MASK;
                    third_start = third_start && data & CORRIDOR_FLAG == CORRIDOR_FLAG;
                    let mut doors = Vec::new();
                    if data & DOOR_FLAG == DOOR_FLAG {
                        for d in Direction::HORIZONTAL {
                            let (dx, dz) = step(d);
                            if grid.get(x + dx, y + dz) == CORRIDOR {
                                doors.push(d);
                            }
                        }
                    }
                    let door = if !doors.is_empty() {
                        Some(Door::Side(
                            doors[self.gc.random.next_int_bounded(doors.len() as i32) as usize],
                        ))
                    } else if data & ORIGIN_FLAG == ORIGIN_FLAG {
                        Some(Door::Up)
                    } else {
                        None
                    };
                    let room_pos = self.cell(floor_origin, rotation, x, y, -1);
                    let door_is = |d: Direction| door == Some(Door::Side(d));
                    if grid.is_house(x - 1, y) && !mansion.is_room_id(x - 1, y, floor, room_id) {
                        let name = if door_is(Direction::West) {
                            door_piece
                        } else {
                            wall_piece
                        };
                        self.add(name, room_pos, rotation, Mirror::None)?;
                    }
                    if grid.get(x + 1, y) == CORRIDOR && !third_start {
                        let pos = relative(room_pos, r(Direction::East), 8);
                        let name = if door_is(Direction::East) {
                            door_piece
                        } else {
                            wall_piece
                        };
                        self.add(name, pos, rotation, Mirror::None)?;
                    }
                    if grid.is_house(x, y + 1) && !mansion.is_room_id(x, y + 1, floor, room_id) {
                        let pos = relative(
                            relative(room_pos, r(Direction::South), 7),
                            r(Direction::East),
                            7,
                        );
                        let name = if door_is(Direction::South) {
                            door_piece
                        } else {
                            wall_piece
                        };
                        self.add(
                            name,
                            pos,
                            rotated(rotation, Rotation::Clockwise90),
                            Mirror::None,
                        )?;
                    }
                    if grid.get(x, y - 1) == CORRIDOR && !third_start {
                        let pos = relative(
                            relative(room_pos, r(Direction::North), 1),
                            r(Direction::East),
                            7,
                        );
                        let name = if door_is(Direction::North) {
                            door_piece
                        } else {
                            wall_piece
                        };
                        self.add(
                            name,
                            pos,
                            rotated(rotation, Rotation::Clockwise90),
                            Mirror::None,
                        )?;
                    }
                    if kind == ROOM_1X1 {
                        self.room_1x1(room_pos, rotation, door, floor)?;
                    } else if kind == ROOM_1X2 {
                        if let Some(door) = door {
                            let room_dir = mansion.room_direction(x, y, floor, room_id);
                            let stairs = data & STAIRS_FLAG == STAIRS_FLAG;
                            self.room_1x2(room_pos, rotation, room_dir, door, floor, stairs)?;
                        }
                    } else if kind == ROOM_2X2 {
                        match door {
                            Some(Door::Side(d)) => {
                                let mut room_dir = d.clockwise();
                                let (dx, dz) = step(room_dir);
                                if !mansion.is_room_id(x + dx, y + dz, floor, room_id) {
                                    room_dir = room_dir.opposite();
                                }
                                self.room_2x2(room_pos, rotation, room_dir, d, floor)?;
                            }
                            Some(Door::Up) => {
                                let pos = relative(room_pos, r(Direction::East), 1);
                                self.add("2x2_s1", pos, rotation, Mirror::None)?;
                            }
                            None => {}
                        }
                    }
                }
            }
        }
        Ok(())
    }
}

/// `WoodlandMansionStructure.findGenerationPoint` and `generateMansion`.
pub fn generate(gc: &mut GenContext) -> Result<Option<Vec<Piece>>, String> {
    let (x, z) = (gc.min_block_x() + 7, gc.min_block_z() + 7);
    if !gc.could_exist_in_terrain_column(x, z)? {
        return Ok(None);
    }
    let rotation = ROTATIONS[gc.random.next_int_bounded(4) as usize];
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
    let grid = MansionGrid::new(&mut gc.random);
    let mut placer = Placer {
        gc,
        pieces: Vec::new(),
        start: (0, 0),
    };
    placer.create([x, y, z], rotation, &grid)?;
    Ok(Some(placer.pieces))
}
