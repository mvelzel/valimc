//! Pistons on the block-update engine (VMC-048b), as vanilla's
//! `PistonBaseBlock`, `PistonStructureResolver`, `PistonHeadBlock`,
//! `MovingPistonBlock` and `PistonMovingBlockEntity` do it: a base that
//! hears power raises a block event (`checkIfExtend`), the block events of
//! a tick run in their own phase (`triggerEvent`: extend, retract, a sticky
//! piston's pull, the short pulse that drops its block), moving blocks carry
//! their block entities (`crate::piston::Moving`) and tick after the
//! entities, ending as the block they carry, and a head goes with its base.
//!
//! What moving blocks do to entities is the physics kernel's: a tick of a
//! moving block reports the push it makes (`Push`), which the owner applies
//! to the entities it holds.

use super::at;
use super::components::facing;
use super::power::Kind;
use super::updater::{Engine, World, ALL, UPDATE_LIMIT};
use crate::piston::Moving;
use crate::worldgen::blocks::BlockTable;
use crate::worldgen::json::Json;

const DOWN: usize = 0;
const UP: usize = 1;
/// `PistonStructureResolver.MAX_PUSH_DEPTH`.
const MAX_PUSH: usize = 12;
/// Block event types.
const EXTEND: i32 = 0;
const CONTRACT: i32 = 1;
const DROP: i32 = 2;
/// `Level.setBlock` flags the classes use.
const MOVED: i32 = 64;
/// UPDATE_INVISIBLE | UPDATE_MOVE_BY_PISTON | UPDATE_SKIP_BLOCK_ENTITY_SIDEEFFECTS.
const PUSHED_FLAGS: i32 = 324;
/// UPDATE_INVISIBLE | UPDATE_KNOWN_SHAPE | UPDATE_SKIP_BLOCK_ENTITY_SIDEEFFECTS.
const SOURCE_FLAGS: i32 = 276;
/// UPDATE_CLIENTS | UPDATE_KNOWN_SHAPE | UPDATE_MOVE_BY_PISTON.
const VACATED_FLAGS: i32 = 82;
/// UPDATE_CLIENTS | UPDATE_KNOWN_SHAPE.
const POPPED_FLAGS: i32 = 18;
/// UPDATE_ALL | UPDATE_MOVE_BY_PISTON.
const EXTENDED_FLAGS: i32 = 67;
/// UPDATE_INVISIBLE | KNOWN_SHAPE | MOVE_BY_PISTON | SKIP_BLOCK_ENTITY_SIDEEFFECTS.
const LANDED_AIR_FLAGS: i32 = 340;

/// `PushReaction`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reaction {
    PushPull,
    Push,
    Popped,
    Immoveable,
    IgnoreEntity,
}

/// What pistons read of the blocks (RedstoneOracle's `pistons` facts).
#[derive(Clone, Debug)]
pub struct PistonFacts {
    /// Per block id.
    reactions: Vec<Reaction>,
    unbreakable: Vec<bool>,
    entities: Vec<bool>,
    pub piston: u16,
    pub sticky_piston: u16,
    pub head: u16,
    pub moving: u16,
    slime: u16,
    honey: u16,
}

impl PistonFacts {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<PistonFacts, String> {
        let n = table.names.len();
        let mut facts = PistonFacts {
            reactions: vec![Reaction::PushPull; n],
            unbreakable: vec![false; n],
            entities: vec![false; n],
            piston: table.block("piston")?,
            sticky_piston: table.block("sticky_piston")?,
            head: table.block("piston_head")?,
            moving: table.block("moving_piston")?,
            slime: table.block("slime_block")?,
            honey: table.block("honey_block")?,
        };
        for (name, reaction) in json.field("reactions")?.entries()? {
            facts.reactions[table.block(name)? as usize] = match reaction.as_str()? {
                "push" => Reaction::Push,
                "popped" => Reaction::Popped,
                "immoveable" => Reaction::Immoveable,
                "ignore_entity" => Reaction::IgnoreEntity,
                other => return Err(format!("piston facts: reaction {other}")),
            };
        }
        for name in json.field("unbreakable")?.as_array()? {
            facts.unbreakable[table.block(name.as_str()?)? as usize] = true;
        }
        for name in json.field("entities")?.as_array()? {
            facts.entities[table.block(name.as_str()?)? as usize] = true;
        }
        Ok(facts)
    }

    pub fn reaction(&self, block: u16) -> Reaction {
        self.reactions[block as usize]
    }

    fn is_base(&self, block: u16) -> bool {
        block == self.piston || block == self.sticky_piston
    }

    fn is_sticky(&self, block: u16) -> bool {
        block == self.slime || block == self.honey
    }

    /// `canStickToEachOther`: slime and honey do not stick together.
    fn stick(&self, a: u16, b: u16) -> bool {
        if (a == self.honey && b == self.slime) || (a == self.slime && b == self.honey) {
            return false;
        }
        self.is_sticky(a) || self.is_sticky(b)
    }
}

/// A moving block's tick, in the order they ran: its cell, the cell's state
/// and its block entity as they were, and its new progress; one that
/// `landed` became its block instead and pushed nothing. The others push
/// (`moveCollidedEntities`, `moveStuckEntities`) while the blocks after them
/// in the order still stand as they were.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Push {
    pub pos: [i32; 3],
    pub moving: Moving,
    pub progress: f32,
    pub state: u16,
    pub landed: bool,
}

/// A block event (`Level.blockEvent`): position, block and its two values.
pub type Event = ([i32; 3], u16, i32, i32);

/// What pistons read beyond the cells, per run.
#[derive(Clone, Debug)]
pub struct Pistons {
    /// The pending block events, in order, each once.
    pub events: std::collections::VecDeque<Event>,
    /// Whether this run is in the tick's first part (`isHandlingTick`:
    /// block ticks, chunk ticks, block events).
    pub handling_tick: bool,
    /// The world border (`isWithinBounds`): min x, min z, max x, max z.
    pub border: [f64; 4],
    /// The level's lowest and highest block y.
    pub min_y: i32,
    pub max_y: i32,
}

impl Default for Pistons {
    fn default() -> Pistons {
        Pistons {
            events: Default::default(),
            handling_tick: false,
            border: [
                f64::NEG_INFINITY,
                f64::NEG_INFINITY,
                f64::INFINITY,
                f64::INFINITY,
            ],
            min_y: crate::column::MIN_Y,
            max_y: crate::column::MIN_Y + crate::column::HEIGHT as i32 - 1,
        }
    }
}

fn step(pos: [i32; 3], d: usize, n: i32) -> [i32; 3] {
    let s = super::STEP[d];
    [pos[0] + s[0] * n, pos[1] + s[1] * n, pos[2] + s[2] * n]
}

fn centre(pos: [i32; 3]) -> [f64; 3] {
    pos.map(|c| c as f64 + 0.5)
}

const FACINGS: [&str; 6] = ["down", "up", "north", "south", "west", "east"];

/// `PistonStructureResolver`'s result.
struct Structure {
    to_push: Vec<[i32; 3]>,
    to_destroy: Vec<[i32; 3]>,
}

/// The iteration order of a Java `HashMap<BlockPos, _>` (`moveBlocks`'s
/// `deleteAfterMove`): buckets of `BlockPos.hashCode` spread by
/// `HashMap.hash`, each in insertion order, over the table's capacity.
struct JavaHashOrder {
    entries: Vec<([i32; 3], u16)>,
    capacity: usize,
}

impl JavaHashOrder {
    fn new() -> JavaHashOrder {
        JavaHashOrder {
            entries: Vec::new(),
            capacity: 16,
        }
    }

    fn bucket(pos: [i32; 3], capacity: usize) -> usize {
        let h = pos[1]
            .wrapping_add(pos[2].wrapping_mul(31))
            .wrapping_mul(31)
            .wrapping_add(pos[0]);
        let spread = h ^ ((h as u32) >> 16) as i32;
        spread as usize & (capacity - 1)
    }

    fn put(&mut self, pos: [i32; 3], state: u16) {
        if let Some(e) = self.entries.iter_mut().find(|(p, _)| *p == pos) {
            e.1 = state;
            return;
        }
        let bucket = Self::bucket(pos, self.capacity);
        let chain = self
            .entries
            .iter()
            .filter(|(p, _)| Self::bucket(*p, self.capacity) == bucket)
            .count();
        self.entries.push((pos, state));
        // A chain of nine treeifies, which a table under 64 resizes instead.
        if chain >= 8 && self.capacity < 64 {
            self.capacity *= 2;
        }
        if self.entries.len() > self.capacity * 3 / 4 {
            self.capacity *= 2;
        }
    }

    fn remove(&mut self, pos: [i32; 3]) {
        self.entries.retain(|(p, _)| *p != pos);
    }

    fn ordered(&self) -> Vec<([i32; 3], u16)> {
        let mut out = self.entries.clone();
        out.sort_by_key(|&(p, _)| Self::bucket(p, self.capacity));
        out
    }
}

impl<W: World> Engine<'_, W> {
    fn piston_facts(&self) -> Option<&PistonFacts> {
        self.rules.power.as_ref()?.pistons.as_ref()
    }

    /// `PistonBaseBlock.getNeighborSignal`: power from any side but its
    /// face, or at the cell above (quasi-connectivity).
    fn piston_signal(&mut self, pos: [i32; 3], push: usize) -> bool {
        for d in 0..6 {
            if d != push && self.has_signal(at(pos, d), d) {
                return true;
            }
        }
        if self.has_signal(pos, DOWN) {
            return true;
        }
        let above = at(pos, UP);
        (0..6).any(|d| d != DOWN && self.has_signal(at(above, d), d))
    }

    /// `checkIfExtend` of the base at `pos` (holding `state`), after its
    /// placement, an update or `setPlacedBy`.
    pub(super) fn check_if_extend(&mut self, pos: [i32; 3], state: u16) {
        let table = self.rules.table.clone();
        let Some(facts) = self.piston_facts().cloned() else {
            return;
        };
        let direction = facing(&table, state);
        let block = table.block_of(state);
        let extended = table.value(state, "extended") == Some("true");
        let decision = self.decide(|e| {
            let extend = e.piston_signal(pos, direction);
            if extend && !extended {
                e.resolve(&facts, pos, direction, true)
                    .is_some()
                    .then_some(EXTEND)
            } else if !extend && extended {
                let pushed = step(pos, direction, 2);
                let pushed_state = e.world.get(pushed);
                let quick = table.block_of(pushed_state) == facts.moving
                    && facing(&table, pushed_state) == direction
                    && e.world.moving(pushed).is_some_and(|m| {
                        m.extending
                            && (m.progress_o < 0.5
                                || e.redstone.time == m.last_ticked
                                || e.pistons.handling_tick)
                    });
                Some(if quick { DROP } else { CONTRACT })
            } else {
                None
            }
        });
        if let Some(Some(event)) = decision {
            self.block_event(pos, block, event, direction as i32);
        }
    }

    /// `Level.blockEvent`: queued once until it runs.
    pub(super) fn block_event(&mut self, pos: [i32; 3], block: u16, b0: i32, b1: i32) {
        self.report.block_events.push((pos, block, b0, b1));
        let event = (pos, block, b0, b1);
        if !self.pistons.events.contains(&event) {
            self.pistons.events.push_back(event);
        }
    }

    /// `ServerLevel.runBlockEvents`: the pending events in order, those
    /// they raise too; an event at a cell past the group waits.
    pub fn run_block_events(&mut self) {
        let mut waiting = std::collections::VecDeque::new();
        while let Some(event) = self.pistons.events.pop_front() {
            if !self.world.owns(event.0) {
                waiting.push_back(event);
                continue;
            }
            if self.trigger_event(event) {
                self.report.executed.push(event);
            }
        }
        self.pistons.events = waiting;
    }

    /// `doBlockEvent`: the event runs while its cell holds its block; a
    /// note block's plays (the owner sounds it), a piston's moves.
    fn trigger_event(&mut self, (pos, block, b0, b1): Event) -> bool {
        let state = self.world.get(pos);
        let table = self.rules.table.clone();
        if table.block_of(state) != block {
            return false;
        }
        match self.kind_of_state(state) {
            // `NoteBlock.triggerEvent`: a mob head's sound needs its block
            // entity (none is kept); the sound's seed is drawn either way.
            Some(Kind::Note) => {
                let custom = table.value(state, "instrument").is_some_and(|name| {
                    self.rules
                        .power
                        .as_ref()
                        .is_some_and(|p| p.instruments.iter().any(|i| i.name == name && i.custom))
                });
                if custom {
                    return false;
                }
                self.world.next_long();
                true
            }
            Some(Kind::Piston { sticky }) => self.piston_event(pos, state, sticky, b0, b1),
            _ => false,
        }
    }

    fn kind_of_state(&self, state: u16) -> Option<Kind> {
        self.rules
            .power
            .as_ref()?
            .component(&self.rules.table, state)
            .map(|c| c.kind)
    }

    /// `PistonBaseBlock.triggerEvent`.
    fn piston_event(&mut self, pos: [i32; 3], state: u16, sticky: bool, b0: i32, b1: i32) -> bool {
        let table = self.rules.table.clone();
        let Some(facts) = self.piston_facts().cloned() else {
            return false;
        };
        let sounds = self
            .rules
            .power
            .as_ref()
            .and_then(|p| p.component(&table, state))
            .map(|c| c.sounds)
            .unwrap_or_default();
        let direction = facing(&table, state);
        let extended = table.with(state, "extended", "true").unwrap_or(state);
        let Some(extend) = self.decide(|e| e.piston_signal(pos, direction)) else {
            return false;
        };
        if extend && (b0 == CONTRACT || b0 == DROP) {
            self.set_block(pos, extended, 2, UPDATE_LIMIT);
            return false;
        }
        if !extend && b0 == EXTEND {
            return false;
        }
        if b0 == EXTEND {
            if !self.move_blocks(&facts, pos, direction, true, sticky) {
                return false;
            }
            self.set_block(pos, extended, EXTENDED_FLAGS, UPDATE_LIMIT);
            let pitch = self.world.next_float() * 0.25 + 0.6;
            self.piston_sound(pos, sounds[0], pitch);
        } else {
            let arm = at(pos, direction);
            if self.world.owns(arm) && self.world.moving(arm).is_some() {
                self.final_tick(arm);
            }
            let moving_state = self.moving_state(&table, &facts, direction, sticky);
            self.set_block(pos, moving_state, SOURCE_FLAGS, UPDATE_LIMIT);
            let base = table
                .with(
                    table.default_state_of(table.block_of(state)),
                    "facing",
                    FACINGS[((b1 & 7) % 6) as usize],
                )
                .unwrap_or(state);
            let order = self.world.next_order();
            self.world.set_moving(
                pos,
                Some(Moving {
                    moved: base,
                    direction: direction as u8,
                    extending: false,
                    source: true,
                    progress: 0.0,
                    progress_o: 0.0,
                    last_ticked: 0,
                    order,
                }),
            );
            self.update_neighbors_at(pos, facts.moving, None);
            self.update_neighbour_shapes(moving_state, pos, 2, UPDATE_LIMIT);
            if sticky {
                let two = step(pos, direction, 2);
                let mut piece = false;
                if self.world.owns(two) {
                    let at_two = self.world.get(two);
                    if table.block_of(at_two) == facts.moving {
                        if let Some(m) = self.world.moving(two) {
                            if m.direction as usize == direction && m.extending {
                                self.final_tick(two);
                                piece = true;
                            }
                        }
                    }
                }
                if !piece {
                    let pull = self.decide(|e| {
                        let moved = e.world.get(two);
                        let block = table.block_of(moved);
                        b0 == CONTRACT
                            && !table.is_air(moved)
                            && e.is_pushable(&facts, moved, two, direction ^ 1, false, direction)
                            && (facts.reaction(block) == Reaction::PushPull || facts.is_base(block))
                    });
                    match pull {
                        Some(true) => {
                            self.move_blocks(&facts, pos, direction, false, sticky);
                        }
                        Some(false) => self.remove_owned(arm),
                        None => {}
                    }
                }
            } else {
                self.remove_owned(arm);
            }
            let pitch = self.world.next_float() * 0.15 + 0.6;
            self.piston_sound(pos, sounds[1], pitch);
        }
        true
    }

    fn piston_sound(&mut self, pos: [i32; 3], sound: u16, pitch: f32) {
        self.report.sounds.push(super::components::Sound {
            pos: centre(pos),
            sound,
            volume: 0.5,
            pitch,
            actor: false,
        });
    }

    fn moving_state(&self, table: &BlockTable, facts: &PistonFacts, d: usize, sticky: bool) -> u16 {
        let state = table.default_state_of(facts.moving);
        let state = table.with(state, "facing", FACINGS[d]).unwrap_or(state);
        table
            .with(state, "type", if sticky { "sticky" } else { "normal" })
            .unwrap_or(state)
    }

    /// `Level.removeBlock(pos, false)` where the group holds `pos`.
    fn remove_owned(&mut self, pos: [i32; 3]) {
        if self.world.owns(pos) {
            self.remove_block(pos);
        } else {
            self.report.stopped += 1;
        }
    }

    /// `PistonBaseBlock.isPushable`.
    fn is_pushable(
        &mut self,
        facts: &PistonFacts,
        state: u16,
        pos: [i32; 3],
        direction: usize,
        allow_destroy: bool,
        connection: usize,
    ) -> bool {
        let p = &self.pistons;
        let (x, z) = (pos[0] as f64, pos[2] as f64);
        if pos[1] < p.min_y
            || pos[1] > p.max_y
            || !(x >= p.border[0] && x < p.border[2] && z >= p.border[1] && z < p.border[3])
        {
            return false;
        }
        let table = self.rules.table.as_ref();
        if table.is_air(state) {
            return true;
        }
        if (direction == DOWN && pos[1] == p.min_y) || (direction == UP && pos[1] == p.max_y) {
            return false;
        }
        let block = table.block_of(state);
        if facts.is_base(block) {
            if table.value(state, "extended") == Some("true") {
                return false;
            }
        } else {
            if facts.unbreakable[block as usize] {
                return false;
            }
            match facts.reaction(block) {
                Reaction::Immoveable => return false,
                Reaction::Popped => return allow_destroy,
                Reaction::Push => return direction == connection,
                Reaction::PushPull | Reaction::IgnoreEntity => {}
            }
        }
        !facts.entities[block as usize]
    }

    /// `PistonStructureResolver.resolve` (reads only).
    fn resolve(
        &mut self,
        facts: &PistonFacts,
        piston: [i32; 3],
        direction: usize,
        extending: bool,
    ) -> Option<Structure> {
        let (push, start) = if extending {
            (direction, at(piston, direction))
        } else {
            (direction ^ 1, step(piston, direction, 2))
        };
        let mut s = Structure {
            to_push: Vec::new(),
            to_destroy: Vec::new(),
        };
        let next = self.world.get(start);
        if !self.is_pushable(facts, next, start, push, false, direction) {
            let block = self.rules.table.block_of(next);
            if extending && facts.reaction(block) == Reaction::Popped {
                s.to_destroy.push(start);
                return Some(s);
            }
            return None;
        }
        if !self.block_line(facts, &mut s, piston, push, start, push) {
            return None;
        }
        let mut i = 0;
        while i < s.to_push.len() {
            let pos = s.to_push[i];
            let state = self.world.get(pos);
            if facts.is_sticky(self.rules.table.block_of(state))
                && !self.branching(facts, &mut s, piston, push, pos)
            {
                return None;
            }
            i += 1;
        }
        Some(s)
    }

    /// `addBlockLine`.
    fn block_line(
        &mut self,
        facts: &PistonFacts,
        s: &mut Structure,
        piston: [i32; 3],
        push: usize,
        start: [i32; 3],
        direction: usize,
    ) -> bool {
        let table = self.rules.table.clone();
        let mut next = self.world.get(start);
        if table.is_air(next) {
            return true;
        }
        if !self.is_pushable(facts, next, start, push, false, direction) {
            return true;
        }
        if start == piston || s.to_push.contains(&start) {
            return true;
        }
        let mut count = 1usize;
        if count + s.to_push.len() > MAX_PUSH {
            return false;
        }
        while facts.is_sticky(table.block_of(next)) {
            let pos = step(start, push ^ 1, count as i32);
            let previous = next;
            next = self.world.get(pos);
            if table.is_air(next)
                || !facts.stick(table.block_of(previous), table.block_of(next))
                || !self.is_pushable(facts, next, pos, push, false, push ^ 1)
                || pos == piston
            {
                break;
            }
            count += 1;
            if count + s.to_push.len() > MAX_PUSH {
                return false;
            }
        }
        let mut added = 0usize;
        for i in (0..count).rev() {
            s.to_push.push(step(start, push ^ 1, i as i32));
            added += 1;
        }
        let mut i = 1;
        loop {
            let pos = step(start, push, i);
            if let Some(collision) = s.to_push.iter().position(|&p| p == pos) {
                reorder_at_collision(&mut s.to_push, added, collision);
                for j in 0..=collision + added {
                    let p = s.to_push[j];
                    let state = self.world.get(p);
                    if facts.is_sticky(table.block_of(state))
                        && !self.branching(facts, s, piston, push, p)
                    {
                        return false;
                    }
                }
                return true;
            }
            next = self.world.get(pos);
            if table.is_air(next) {
                return true;
            }
            if !self.is_pushable(facts, next, pos, push, true, push) || pos == piston {
                return false;
            }
            if facts.reaction(table.block_of(next)) == Reaction::Popped {
                s.to_destroy.push(pos);
                return true;
            }
            if s.to_push.len() >= MAX_PUSH {
                return false;
            }
            s.to_push.push(pos);
            added += 1;
            i += 1;
        }
    }

    /// `addBranchingBlocks`: the sides of a sticky block across the push.
    fn branching(
        &mut self,
        facts: &PistonFacts,
        s: &mut Structure,
        piston: [i32; 3],
        push: usize,
        from: [i32; 3],
    ) -> bool {
        let table = self.rules.table.clone();
        let from_state = self.world.get(from);
        for d in 0..6 {
            if d / 2 == push / 2 {
                continue;
            }
            let neighbour = at(from, d);
            let state = self.world.get(neighbour);
            if facts.stick(table.block_of(state), table.block_of(from_state))
                && !self.block_line(facts, s, piston, push, neighbour, d)
            {
                return false;
            }
        }
        true
    }

    /// `PistonBaseBlock.moveBlocks`.
    fn move_blocks(
        &mut self,
        facts: &PistonFacts,
        piston: [i32; 3],
        direction: usize,
        extending: bool,
        sticky: bool,
    ) -> bool {
        let table = self.rules.table.clone();
        let arm = at(piston, direction);
        if !extending && self.world.owns(arm) && table.block_of(self.world.get(arm)) == facts.head {
            let air = table.default_state("air").unwrap_or(0);
            self.set_block(arm, air, SOURCE_FLAGS, UPDATE_LIMIT);
        }
        let Some(Some(structure)) = self.decide(|e| e.resolve(facts, piston, direction, extending))
        else {
            return false;
        };
        let mut delete = JavaHashOrder::new();
        let mut shapes = Vec::with_capacity(structure.to_push.len());
        for &pos in &structure.to_push {
            let state = self.world.get(pos);
            shapes.push(state);
            delete.put(pos, state);
        }
        let push = if extending { direction } else { direction ^ 1 };
        let mut to_update =
            Vec::with_capacity(structure.to_push.len() + structure.to_destroy.len());
        let air = table.default_state("air").unwrap_or(0);
        for &pos in structure.to_destroy.iter().rev() {
            let state = self.world.get(pos);
            // `dropResources`: its loot drops; the break effects are the
            // client's own (it moves the blocks itself).
            self.report.destroyed.push(super::updater::Destroyed {
                pos,
                state,
                drops: true,
                effects: false,
            });
            self.set_block(pos, air, POPPED_FLAGS, UPDATE_LIMIT);
            to_update.push(state);
        }
        let moving_plain = self.moving_state(&table, facts, direction, false);
        for i in (0..structure.to_push.len()).rev() {
            let from = structure.to_push[i];
            let state = self.world.get(from);
            let pos = at(from, push);
            delete.remove(pos);
            self.set_block(pos, moving_plain, PUSHED_FLAGS, UPDATE_LIMIT);
            let order = self.world.next_order();
            self.world.set_moving(
                pos,
                Some(Moving {
                    moved: shapes[i],
                    direction: direction as u8,
                    extending,
                    source: false,
                    progress: 0.0,
                    progress_o: 0.0,
                    last_ticked: 0,
                    order,
                }),
            );
            to_update.push(state);
        }
        if extending {
            let head = table.default_state_of(facts.head);
            let head = table
                .with(head, "facing", FACINGS[direction])
                .unwrap_or(head);
            let head = table
                .with(head, "type", if sticky { "sticky" } else { "normal" })
                .unwrap_or(head);
            let moving_state = self.moving_state(&table, facts, direction, sticky);
            delete.remove(arm);
            self.set_block(arm, moving_state, PUSHED_FLAGS, UPDATE_LIMIT);
            let order = self.world.next_order();
            self.world.set_moving(
                arm,
                Some(Moving {
                    moved: head,
                    direction: direction as u8,
                    extending: true,
                    source: true,
                    progress: 0.0,
                    progress_o: 0.0,
                    last_ticked: 0,
                    order,
                }),
            );
        }
        let vacated = delete.ordered();
        for &(pos, _) in &vacated {
            self.set_block(pos, air, VACATED_FLAGS, UPDATE_LIMIT);
        }
        for &(pos, old) in &vacated {
            self.indirect_shapes(old, pos, 2, UPDATE_LIMIT);
            self.update_neighbour_shapes(air, pos, 2, UPDATE_LIMIT);
            self.indirect_shapes(air, pos, 2, UPDATE_LIMIT);
        }
        let mut index = 0;
        for &pos in structure.to_destroy.iter().rev() {
            let state = to_update[index];
            index += 1;
            self.removed(pos, state, false);
            self.indirect_shapes(state, pos, 2, UPDATE_LIMIT);
            self.update_neighbors_at(pos, table.block_of(state), None);
        }
        for &pos in structure.to_push.iter().rev() {
            let state = to_update[index];
            index += 1;
            self.update_neighbors_at(pos, table.block_of(state), None);
        }
        if extending {
            self.update_neighbors_at(arm, facts.head, None);
        }
        true
    }

    /// `PistonMovingBlockEntity.finalTick`: a moving block not yet at rest
    /// lands at once (a source ends as air).
    fn final_tick(&mut self, pos: [i32; 3]) {
        let Some(moving) = self.world.moving(pos) else {
            return;
        };
        if moving.progress_o >= 1.0 {
            return;
        }
        let Some(facts) = self.piston_facts().cloned() else {
            return;
        };
        self.world.set_moving(pos, None);
        let table = self.rules.table.clone();
        if table.block_of(self.world.get(pos)) != facts.moving {
            return;
        }
        let new = if moving.source {
            table.default_state("air").unwrap_or(0)
        } else {
            self.neighbour_shaped(moving.moved, pos)
        };
        self.set_block(pos, new, ALL, UPDATE_LIMIT);
        self.neighbor_changed_at(pos, table.block_of(new));
    }

    /// `Block.updateFromNeighbourShapes`: the state as its neighbours shape
    /// it, in `UPDATE_SHAPE_ORDER`; one that reads past the group stays.
    fn neighbour_shaped(&mut self, state: u16, pos: [i32; 3]) -> u16 {
        let rules = self.rules;
        self.decide(|e| {
            let mut new = state;
            for d in super::updater::UPDATE_SHAPE_ORDER {
                let neighbour = at(pos, d);
                let neighbour_state = e.world.get(neighbour);
                if let Ok(s) = rules.live_update_shape(
                    &mut e.world,
                    new,
                    pos,
                    d,
                    Some((neighbour, neighbour_state)),
                ) {
                    new = s;
                }
            }
            new
        })
        .unwrap_or(state)
    }

    /// `PistonMovingBlockEntity.tick` of the moving block at `pos` at the
    /// game time: it advances half a block (the push it makes is reported)
    /// or, once there, lands as its block.
    pub fn moving_tick(&mut self, pos: [i32; 3]) {
        if !self.world.owns(pos) {
            return;
        }
        let Some(mut moving) = self.world.moving(pos) else {
            return;
        };
        let Some(facts) = self.piston_facts().cloned() else {
            return;
        };
        let before = moving;
        let state = self.world.get(pos);
        moving.last_ticked = self.redstone.time;
        moving.progress_o = moving.progress;
        if moving.progress_o >= 1.0 {
            self.report.pushes.push(Push {
                pos,
                moving: before,
                progress: before.progress,
                state,
                landed: true,
            });
            self.world.set_moving(pos, None);
            let table = self.rules.table.clone();
            if table.block_of(self.world.get(pos)) != facts.moving {
                return;
            }
            let new = self.neighbour_shaped(moving.moved, pos);
            if table.is_air(new) {
                self.set_block(pos, moving.moved, LANDED_AIR_FLAGS, UPDATE_LIMIT);
                self.update_or_destroy(moving.moved, new, pos, ALL, UPDATE_LIMIT);
            } else {
                let new = if table.value(new, "waterlogged") == Some("true") {
                    table.with(new, "waterlogged", "false").unwrap_or(new)
                } else {
                    new
                };
                self.set_block(pos, new, EXTENDED_FLAGS, UPDATE_LIMIT);
                self.neighbor_changed_at(pos, table.block_of(new));
            }
        } else {
            let progress = moving.progress + 0.5;
            self.report.pushes.push(Push {
                pos,
                moving: Moving {
                    progress_o: moving.progress_o,
                    last_ticked: moving.last_ticked,
                    ..before
                },
                progress,
                state,
                landed: false,
            });
            moving.progress = progress.min(1.0);
            self.world.set_moving(pos, Some(moving));
        }
    }

    /// `PistonHeadBlock.neighborChanged`: a head that stands tells its
    /// base.
    pub(super) fn head_neighbor_changed(&mut self, pos: [i32; 3], state: u16, source: u16) -> bool {
        let Some(facts) = self.piston_facts().cloned() else {
            return false;
        };
        let table = self.rules.table.clone();
        if table.block_of(state) != facts.head {
            return false;
        }
        let base = at(pos, facing(&table, state) ^ 1);
        if let Some(true) = self.decide(|e| head_survives(&table, &facts, state, e.world.get(base)))
        {
            self.neighbor_changed_at(base, source);
        }
        true
    }

    /// `PistonHeadBlock.affectNeighborsAfterRemoval`: its fitting base
    /// breaks with it.
    pub(super) fn head_removed(&mut self, pos: [i32; 3], state: u16) -> bool {
        let Some(facts) = self.piston_facts().cloned() else {
            return false;
        };
        let table = self.rules.table.clone();
        if table.block_of(state) != facts.head {
            return false;
        }
        let base = at(pos, facing(&table, state) ^ 1);
        if self.world.owns(base) && fitting_base(&table, &facts, state, self.world.get(base)) {
            self.destroy(base, true, UPDATE_LIMIT);
        }
        true
    }

    /// A piston base's `onPlace` (a new base, without a block entity) and
    /// `setPlacedBy`.
    pub(super) fn piston_placed(&mut self, pos: [i32; 3], old: u16, state: u16) -> bool {
        let table = self.rules.table.clone();
        let Some(facts) = self.piston_facts() else {
            return false;
        };
        let block = table.block_of(state);
        if !facts.is_base(block) {
            return false;
        }
        if table.block_of(old) != block {
            self.check_if_extend(pos, state);
        }
        true
    }

    /// Whether a run's `flags` move the block (`UPDATE_MOVE_BY_PISTON`).
    pub(super) fn moved_by_piston(flags: i32) -> bool {
        flags & MOVED != 0
    }
}

/// `isFittingBase`.
fn fitting_base(table: &BlockTable, facts: &PistonFacts, head: u16, base: u16) -> bool {
    let wanted = if table.value(head, "type") == Some("sticky") {
        facts.sticky_piston
    } else {
        facts.piston
    };
    table.block_of(base) == wanted
        && table.value(base, "extended") == Some("true")
        && table.value(base, "facing") == table.value(head, "facing")
}

/// `PistonHeadBlock.canSurvive`: a fitting base, or a moving piston facing
/// its way.
pub(super) fn head_survives(table: &BlockTable, facts: &PistonFacts, head: u16, base: u16) -> bool {
    fitting_base(table, facts, head, base)
        || (table.block_of(base) == facts.moving
            && table.value(base, "facing") == table.value(head, "facing"))
}

/// `reorderListAtCollision`.
fn reorder_at_collision(list: &mut Vec<[i32; 3]>, added: usize, collision: usize) {
    let n = list.len();
    let head = list[..collision].to_vec();
    let last = list[n - added..].to_vec();
    let middle = list[collision..n - added].to_vec();
    list.clear();
    list.extend(head);
    list.extend(last);
    list.extend(middle);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn java_hash_order_follows_buckets_then_insertion() {
        let mut map = JavaHashOrder::new();
        // hashCode (y + z*31)*31 + x: x=16 and x=0 share bucket 0 of 16.
        map.put([16, 0, 0], 1);
        map.put([1, 0, 0], 2);
        map.put([0, 0, 0], 3);
        let order: Vec<_> = map.ordered().into_iter().map(|(_, s)| s).collect();
        assert_eq!(order, vec![1, 3, 2]);
    }

    #[test]
    fn a_collision_moves_the_last_line_before_the_rest() {
        let mut list = vec![[0, 0, 0], [1, 0, 0], [2, 0, 0], [9, 0, 0], [8, 0, 0]];
        reorder_at_collision(&mut list, 2, 1);
        assert_eq!(
            list,
            vec![[0, 0, 0], [9, 0, 0], [8, 0, 0], [1, 0, 0], [2, 0, 0]]
        );
    }
}
