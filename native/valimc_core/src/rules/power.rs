//! Redstone power (VMC-047a, VMC-048a): what the signal sources and the
//! blocks that react to power are, from RedstoneOracle's facts
//! (`priv/physics/redstone.json`), and vanilla's `SignalGetter` reads as live
//! play makes them, wire included (its `shouldSignal` on). Wire's own
//! evaluation reads with wire silent (`wire.rs`). A comparator's signal is its
//! block entity's output, which the level holds (`BlockAccess::comparator_output`).
//! Analog outputs (what comparators read) come from the facts per state, or
//! from the owner's block entity (`World::container_signal`). The reactions
//! are `components.rs`.
//!
//! The facts also carry the overworld's day cycle as daylight detectors read
//! it: `SKY_LIGHT_LEVEL` (the dimension's value, the day timeline's
//! multiplier and the weather's blends) and `SUN_ANGLE` (the timeline's eased
//! keyframes), sampled as `KeyframeTrackSampler` does.

use super::at;
use super::updater::{Engine, World};
use super::BlockAccess;
use crate::worldgen::blocks::{BlockTable, REDSTONE_CONDUCTOR, SIGNAL_SOURCE};
use crate::worldgen::json::Json;

const DOWN: usize = 0;
const UP: usize = 1;

/// What a block does with power, with its own parameters.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    Lever,
    /// `ButtonBlock`: how long it stays pressed and whether arrows press it.
    Button {
        ticks: i32,
        arrows: bool,
    },
    /// `PressurePlateBlock`: whether only living entities press it.
    Plate {
        mobs: bool,
    },
    /// `WeightedPressurePlateBlock`.
    Weighted {
        max: i32,
    },
    Torch,
    WallTorch,
    Lamp,
    /// Doors, trapdoors: whether a hand opens them.
    Door {
        hand: bool,
    },
    Trapdoor {
        hand: bool,
    },
    Gate,
    Note,
    Tnt,
    Target,
    Daylight,
    Hook,
    Tripwire,
    Lectern,
    /// `RepeaterBlock`, `ComparatorBlock` (VMC-048a).
    Repeater,
    Comparator,
    Observer,
    /// `PistonBaseBlock` (VMC-048b): sticky or not.
    Piston {
        sticky: bool,
    },
    /// `HopperBlock` (VMC-049a): power locks it.
    Hopper,
    /// `DispenserBlock` and `DropperBlock` (VMC-049a): a rising edge fires
    /// it four ticks later.
    Dispenser {
        dropper: bool,
    },
}

/// An analog output's value for a state (`getAnalogOutputSignal`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Analog {
    None,
    /// The state alone gives it.
    Value(i32),
    /// Its block entity does (a container's fullness): the owner's.
    Entity,
}

/// A block's component: its kind and its sounds (indices into
/// `PowerFacts::sounds`), in the order the facts give them.
#[derive(Clone, Copy, Debug)]
pub struct Component {
    pub kind: Kind,
    pub sounds: [u16; 4],
}

/// A note block instrument (`NoteBlockInstrument`).
#[derive(Clone, Debug)]
pub struct Instrument {
    pub name: String,
    /// `worksAboveNoteBlock`: a block over the note block plays it.
    pub above: bool,
    /// `hasCustomSound`: a mob head above names it.
    pub custom: bool,
}

/// A float track of the day timeline (`KeyframeTrackSampler` with a period).
#[derive(Clone, Debug, Default)]
pub struct Track {
    keyframes: Vec<(i32, f32)>,
    /// A cubic Bézier easing's controls (`x1, y1, x2, y2`), else linear.
    bezier: Option<[f32; 4]>,
}

/// The overworld's day cycle as daylight detectors read it.
#[derive(Clone, Debug, Default)]
pub struct Day {
    period: i64,
    /// The dimension's `SKY_LIGHT_LEVEL`.
    base: f32,
    /// The timeline's multiplier of it.
    sky: Track,
    /// The weather's `ALPHA_BLEND` arguments (value, alpha): rain, thunder.
    rain: (f32, f32),
    thunder: (f32, f32),
    sun: Track,
}

#[derive(Debug, Default)]
pub struct PowerFacts {
    /// Per block id.
    components: Vec<Option<Component>>,
    pub sounds: Vec<String>,
    /// Outline bounds (block-local, min then max) of buttons and tripwire,
    /// by state, which their entity checks read.
    bounds: Vec<(u16, [f64; 6])>,
    pub instruments: Vec<Instrument>,
    pub day: Day,
    pub tripwire: u16,
    pub hook: u16,
    /// `BlockTags.WALLS` (fence gates).
    walls: crate::worldgen::blocks::BlockSet,
    /// Per state, its analog output: -1 none, -2 its block entity's, else
    /// the value.
    analog: Vec<i8>,
    /// Per block, whether its removal tells comparators
    /// (`Containers.updateNeighboursAfterDestroy`).
    removal_output: Vec<bool>,
    /// What pistons read of the blocks (VMC-048b), when given.
    pub pistons: Option<super::piston::PistonFacts>,
}

impl PowerFacts {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<PowerFacts, String> {
        let mut facts = PowerFacts {
            components: vec![None; table.names.len()],
            tripwire: table.block("tripwire")?,
            hook: table.block("tripwire_hook")?,
            walls: table.tag("minecraft:walls")?.clone(),
            ..PowerFacts::default()
        };
        for entry in json.field("components")?.as_array()? {
            let block = table.block(entry.field("block")?.as_str()?)?;
            let int = |key: &str| entry.field(key).and_then(Json::as_i32);
            let flag = |key: &str| entry.field(key).and_then(Json::as_bool);
            let kind = match entry.field("kind")?.as_str()? {
                "lever" => Kind::Lever,
                "button" => Kind::Button {
                    ticks: int("ticks")?,
                    arrows: flag("arrows")?,
                },
                "plate" => Kind::Plate {
                    mobs: flag("mobs")?,
                },
                "weighted" => Kind::Weighted { max: int("max")? },
                "torch" => Kind::Torch,
                "wall_torch" => Kind::WallTorch,
                "lamp" => Kind::Lamp,
                "door" => Kind::Door {
                    hand: flag("hand")?,
                },
                "trapdoor" => Kind::Trapdoor {
                    hand: flag("hand")?,
                },
                "gate" => Kind::Gate,
                "note" => Kind::Note,
                "tnt" => Kind::Tnt,
                "target" => Kind::Target,
                "daylight" => Kind::Daylight,
                "hook" => Kind::Hook,
                "tripwire" => Kind::Tripwire,
                "lectern" => Kind::Lectern,
                "repeater" => Kind::Repeater,
                "comparator" => Kind::Comparator,
                "observer" => Kind::Observer,
                "piston" => Kind::Piston {
                    sticky: flag("sticky")?,
                },
                "hopper" => Kind::Hopper,
                "dispenser" => Kind::Dispenser {
                    dropper: flag("dropper")?,
                },
                other => return Err(format!("redstone facts: kind {other}")),
            };
            let mut sounds = [0; 4];
            if let Some(names) = entry.get("sounds") {
                for (i, name) in names.as_array()?.iter().enumerate().take(4) {
                    let name = name.as_str()?;
                    let index = match facts.sounds.iter().position(|s| s == name) {
                        Some(index) => index,
                        None => {
                            facts.sounds.push(name.to_string());
                            facts.sounds.len() - 1
                        }
                    };
                    sounds[i] = index as u16;
                }
            }
            facts.components[block as usize] = Some(Component { kind, sounds });
        }
        for row in json.field("bounds")?.as_array()? {
            let row = row.as_array()?;
            let value =
                |i: usize| -> Result<f64, String> { row.get(i).ok_or("redstone bounds")?.as_f64() };
            let state = value(0)? as u16;
            facts.bounds.push((
                state,
                [
                    value(1)?,
                    value(2)?,
                    value(3)?,
                    value(4)?,
                    value(5)?,
                    value(6)?,
                ],
            ));
        }
        facts.bounds.sort_by_key(|&(state, _)| state);
        for entry in json.field("instruments")?.as_array()? {
            facts.instruments.push(Instrument {
                name: entry.field("name")?.as_str()?.to_string(),
                above: entry.field("above")?.as_bool()?,
                custom: entry.field("custom")?.as_bool()?,
            });
        }
        facts.analog = vec![-1; table.block_of.len()];
        facts.removal_output = vec![false; table.names.len()];
        for entry in json.field("analog")?.as_array()? {
            let entry = entry.as_array()?;
            let name = entry.first().ok_or("redstone analog")?.as_str()?;
            let block = table.block(name)?;
            let states = table.states_of(block).collect::<Vec<_>>();
            let values = entry.get(1).ok_or("redstone analog")?;
            match values.as_array() {
                Ok(values) => {
                    if values.len() != states.len() {
                        return Err(format!(
                            "redstone analog: {name} has {} states",
                            states.len()
                        ));
                    }
                    for (&state, value) in states.iter().zip(values) {
                        facts.analog[state as usize] = value.as_i32()?.clamp(0, 15) as i8;
                    }
                }
                Err(_) => {
                    for &state in &states {
                        facts.analog[state as usize] = -2;
                    }
                }
            }
            facts.removal_output[block as usize] =
                entry.get(2).ok_or("redstone analog")?.as_bool()?;
        }
        facts.day = Day::parse(json.field("day")?)?;
        facts.pistons = json
            .get("pistons")
            .map(|p| super::piston::PistonFacts::parse(p, table))
            .transpose()?;
        Ok(facts)
    }

    /// A state's analog output (`hasAnalogOutputSignal`, its value).
    pub fn analog(&self, state: u16) -> Analog {
        match self.analog.get(state as usize).copied().unwrap_or(-1) {
            -1 => Analog::None,
            -2 => Analog::Entity,
            v => Analog::Value(v as i32),
        }
    }

    /// Whether removing `state`'s block tells comparators.
    pub fn removal_output(&self, table: &BlockTable, state: u16) -> bool {
        self.removal_output
            .get(table.block_of(state) as usize)
            .copied()
            .unwrap_or(false)
    }

    pub fn component(&self, table: &BlockTable, state: u16) -> Option<Component> {
        self.components
            .get(table.block_of(state) as usize)
            .copied()
            .flatten()
    }

    /// A button's or tripwire's outline bounds at `pos`.
    pub fn bounds(&self, state: u16, pos: [i32; 3]) -> [f64; 6] {
        let local = match self.bounds.binary_search_by_key(&state, |&(s, _)| s) {
            Ok(i) => self.bounds[i].1,
            Err(_) => [0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
        };
        let p = pos.map(f64::from);
        [
            local[0] + p[0],
            local[1] + p[1],
            local[2] + p[2],
            local[3] + p[0],
            local[4] + p[1],
            local[5] + p[2],
        ]
    }
}

impl Track {
    fn parse(json: &Json) -> Result<Track, String> {
        let mut keyframes = Vec::new();
        for frame in json.field("keyframes")?.as_array()? {
            let frame = frame.as_array()?;
            let ticks = frame.first().ok_or("keyframe")?.as_i32()?;
            let value = frame.get(1).ok_or("keyframe")?.as_f64()? as f32;
            keyframes.push((ticks, value));
        }
        let bezier = match json.get("bezier") {
            Some(controls) => {
                let c = controls.as_array()?;
                let at = |i: usize| -> Result<f32, String> {
                    Ok(c.get(i).ok_or("bezier")?.as_f64()? as f32)
                };
                Some([at(0)?, at(1)?, at(2)?, at(3)?])
            }
            None => None,
        };
        Ok(Track { keyframes, bezier })
    }

    /// `KeyframeTrackSampler.sample` over `period` ticks, with float lerp.
    fn sample(&self, period: i64, ticks: i64) -> f32 {
        let frames = &self.keyframes;
        if frames.len() == 1 {
            return frames[0].1;
        }
        let first = frames[0];
        let last = frames[frames.len() - 1];
        // `bakeSegments` with a period: last → first, then each pair, then
        // last → first a period on.
        let mut segments = Vec::with_capacity(frames.len() + 1);
        segments.push((last.1, last.0 - period as i32, first.1, first.0));
        for pair in frames.windows(2) {
            segments.push((pair[0].1, pair[0].0, pair[1].1, pair[1].0));
        }
        segments.push((last.1, last.0, first.1, first.0 + period as i32));
        let t = ticks.rem_euclid(period);
        let segment = segments
            .iter()
            .find(|s| t < s.3 as i64)
            .unwrap_or(&segments[segments.len() - 1]);
        let (from_value, from, to_value, to) = *segment;
        if t <= from as i64 {
            return from_value;
        }
        if t >= to as i64 {
            return to_value;
        }
        let alpha = (t - from as i64) as f32 / (to - from) as f32;
        let eased = match self.bezier {
            Some(controls) => bezier(controls, alpha),
            None => alpha,
        };
        lerp(eased, from_value, to_value)
    }
}

/// `Mth.lerp` on floats.
fn lerp(alpha: f32, from: f32, to: f32) -> f32 {
    from + alpha * (to - from)
}

/// `EasingType.CubicBezier.apply`.
fn bezier([x1, y1, x2, y2]: [f32; 4], x: f32) -> f32 {
    let curve = |v1: f32, v2: f32| (3.0 * v1 - 3.0 * v2 + 1.0, -6.0 * v1 + 3.0 * v2, 3.0 * v1);
    let sample = |(a, b, c): (f32, f32, f32), t: f32| ((a * t + b) * t + c) * t;
    let gradient = |(a, b, c): (f32, f32, f32), t: f32| (3.0 * a * t + 2.0 * b) * t + c;
    let (xc, yc) = (curve(x1, x2), curve(y1, y2));
    let solve = || {
        let mut t = x;
        for _ in 0..4 {
            let error = sample(xc, t) - x;
            if error.abs() < 1.0e-5 {
                return t;
            }
            let slope = gradient(xc, t);
            if slope < 1.0e-5 {
                break;
            }
            t -= (error / slope).clamp(-0.25, 0.25);
        }
        // `solveTBisect`.
        let (mut t0, mut t1) = (0.0f32, 1.0f32);
        while t0 < t1 {
            let error = sample(xc, t) - x;
            if error.abs() < 1.0e-5 {
                return t;
            }
            if error < 0.0 {
                t0 = t;
            } else {
                t1 = t;
            }
            t = (t1 + t0) / 2.0;
        }
        t
    };
    sample(yc, solve())
}

impl Day {
    fn parse(json: &Json) -> Result<Day, String> {
        let pair = |key: &str| -> Result<(f32, f32), String> {
            let p = json.field(key)?.as_array()?;
            Ok((
                p.first().ok_or("day")?.as_f64()? as f32,
                p.get(1).ok_or("day")?.as_f64()? as f32,
            ))
        };
        Ok(Day {
            period: json.field("period")?.as_i32()? as i64,
            base: json.field("base")?.as_f64()? as f32,
            sky: Track::parse(json.field("sky_light_level")?)?,
            rain: pair("rain")?,
            thunder: pair("thunder")?,
            sun: Track::parse(json.field("sun_angle")?)?,
        })
    }

    /// `Level.skyDarken` at the clock's `ticks` and the weather's levels
    /// (`getRainLevel`, `getThunderLevel`): 15 less `SKY_LIGHT_LEVEL`.
    pub fn sky_darken(&self, ticks: i64, rain: f32, thunder: f32) -> i32 {
        let mut level = self.base * self.sky.sample(self.period, ticks);
        // `WeatherAttributes`' layer: rain without thunder, then thunder.
        let rain = rain - thunder;
        if rain > 0.0 {
            level = lerp(rain, level, lerp(self.rain.1, level, self.rain.0));
        }
        if thunder > 0.0 {
            level = lerp(thunder, level, lerp(self.thunder.1, level, self.thunder.0));
        }
        (15.0 - level.clamp(0.0, 15.0)) as i32
    }

    /// `SUN_ANGLE` in degrees at the clock's `ticks`.
    pub fn sun_angle(&self, ticks: i64) -> f32 {
        self.sun.sample(self.period, ticks)
    }
}

/// `DaylightDetectorBlock.updateSignalStrength`'s target power from the
/// effective sky brightness and the sun angle in degrees.
pub fn daylight_power(brightness: i32, sun_degrees: f32, inverted: bool) -> i32 {
    let mut target = brightness;
    let mut sun = sun_degrees * (std::f64::consts::PI / 180.0) as f32;
    if inverted {
        target = 15 - target;
    } else if target > 0 {
        let pi = std::f64::consts::PI as f32;
        let offset = if sun < pi {
            0.0
        } else {
            (std::f64::consts::PI * 2.0) as f32
        };
        sun += (offset - sun) * 0.2;
        let cos = crate::worldgen::carver::cos(sun as f64);
        target = java_round(target as f32 * cos);
    }
    target.clamp(0, 15)
}

/// Java's `Math.round(float)`.
fn java_round(x: f32) -> i32 {
    (x + 0.5).floor() as i32
}

impl super::Rules {
    /// The shape updates of the components the shape facts leave out, in
    /// live play: tripwire connects to tripwire and to hooks facing it, a
    /// tripwire hook, lever or button falls off the face it hangs on, and a
    /// fence gate sinks into a wall beside it (`isWall`). A lever or button
    /// live play's survival facts cover is theirs.
    pub(super) fn component_shape(
        &self,
        access: &mut dyn super::BlockAccess,
        state: u16,
        pos: [i32; 3],
        d: usize,
        replaced: Option<([i32; 3], u16)>,
    ) -> Option<u16> {
        let facts = self.power.as_ref()?;
        let kind = facts.component(&self.table, state)?.kind;
        let table = self.table.as_ref();
        let neighbour = match replaced {
            Some((p, s)) if p == at(pos, d) => s,
            _ => access.get(at(pos, d)),
        };
        let neighbour = self.supporting(access, at(pos, d), neighbour);
        let facing = |state: u16| super::components::facing(table, state);
        let air = table.default_state("air").ok()?;
        match kind {
            Kind::Tripwire if d >= 2 => {
                let connects = if table.block_of(neighbour) == facts.hook {
                    facing(neighbour) == d ^ 1
                } else {
                    table.block_of(neighbour) == facts.tripwire
                };
                table.with(state, NAMES[d], if connects { "true" } else { "false" })
            }
            Kind::Tripwire => Some(state),
            Kind::Hook => {
                let f = facing(state);
                if d ^ 1 != f {
                    return Some(state);
                }
                let behind = access.get(at(pos, f ^ 1));
                let behind = self.supporting(access, at(pos, f ^ 1), behind);
                let survives = f >= 2 && table.flag(behind, crate::worldgen::blocks::STURDY << f);
                Some(if survives { state } else { air })
            }
            Kind::Lever | Kind::Button { .. } => {
                if self.live.as_ref().is_some_and(|l| l.dependent(state)) {
                    return None;
                }
                let connected = match table.value(state, "face") {
                    Some("ceiling") => DOWN,
                    Some("floor") => UP,
                    _ => facing(state),
                };
                if connected ^ 1 != d {
                    return Some(state);
                }
                let attached = access.get(at(pos, d));
                let attached = self.supporting(access, at(pos, d), attached);
                let survives = table.flag(attached, crate::worldgen::blocks::STURDY << (d ^ 1));
                Some(if survives { state } else { air })
            }
            Kind::Repeater | Kind::Comparator => {
                if d == DOWN && !self.diode_survives(access, state, pos, Some(neighbour)) {
                    return Some(air);
                }
                // A repeater's lock follows its sides (and an update from above
                // or below), as the level holds them.
                if kind == Kind::Repeater && d / 2 != facing(state) / 2 {
                    let locked = self.repeater_locked(access, pos, state);
                    return table.with(state, "locked", if locked { "true" } else { "false" });
                }
                Some(state)
            }
            Kind::Observer => {
                // `startSignal`: what it faces changed shape.
                let block = table.block_of(state);
                if facing(state) == d
                    && table.value(state, "powered") != Some("true")
                    && !access.has_block_tick(pos, block)
                {
                    access.schedule_block_tick(pos, block, 2);
                }
                Some(state)
            }
            Kind::Gate => {
                // `getClockWise`: north to east, east to south, south to west,
                // west to north; an axis is its directions' pair.
                let clockwise = [0, 1, 5, 4, 2, 3][facing(state)];
                if clockwise / 2 != d / 2 {
                    return Some(state);
                }
                let walls = &facts.walls;
                let opposite = access.get(at(pos, d ^ 1));
                let in_wall = table.in_tag(neighbour, walls) || table.in_tag(opposite, walls);
                table.with(state, "in_wall", if in_wall { "true" } else { "false" })
            }
            _ => None,
        }
    }
}

const NAMES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];

impl super::Rules {
    /// `DiodeBlock.canSurvive`: a rigid floor (live play's survival facts),
    /// the floor read as `below` where an update gives it.
    pub(super) fn diode_survives(
        &self,
        access: &mut dyn BlockAccess,
        state: u16,
        pos: [i32; 3],
        below: Option<u16>,
    ) -> bool {
        let Some(live) = self.live.as_ref().filter(|l| l.dependent(state)) else {
            return true;
        };
        let floor = at(pos, DOWN);
        let mut read = |p: [i32; 3]| match below {
            Some(s) if p == floor => s,
            _ => {
                let s = access.get(p);
                self.supporting(access, p, s)
            }
        };
        live.survives(state, pos, &mut read)
    }

    /// A diode's `getSignal` toward `d` (a repeater's from its state, a
    /// comparator's its output): its own signal toward its front, while
    /// powered.
    fn comparator_signal(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        state: u16,
        d: usize,
    ) -> i32 {
        let table = self.table.as_ref();
        if super::components::facing(table, state) == d
            && table.value(state, "powered") == Some("true")
        {
            access.comparator_output(pos)
        } else {
            0
        }
    }

    /// `state.getSignal(level, pos, d)` with wire silent: the facts', a
    /// comparator's from its output.
    pub(super) fn block_signal(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        state: u16,
        d: usize,
    ) -> i32 {
        if self.table.block_of(state) == self.redstone.comparator {
            self.comparator_signal(access, pos, state, d)
        } else {
            self.table.signal(state, d)
        }
    }

    /// `state.getDirectSignal(level, pos, d)` with wire silent.
    pub(super) fn block_direct_signal(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        state: u16,
        d: usize,
    ) -> i32 {
        if self.table.block_of(state) == self.redstone.comparator {
            self.comparator_signal(access, pos, state, d)
        } else {
            self.table.direct_signal(state, d)
        }
    }

    /// `state.getSignal(level, pos, d)` with wire signalling: wire gives its
    /// power down and to the sides it connects to (its connections as the
    /// level makes them), never up.
    pub(super) fn state_signal(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        state: u16,
        d: usize,
    ) -> i32 {
        let table = self.table.as_ref();
        if table.block_of(state) != self.redstone.wire {
            return self.block_signal(access, pos, state, d);
        }
        let power: i32 = table
            .value(state, "power")
            .and_then(|p| p.parse().ok())
            .unwrap_or(0);
        if d == DOWN || power == 0 {
            return 0;
        }
        if d == UP {
            return power;
        }
        let mut read = |p: [i32; 3]| access.get(p);
        let connected = self.redstone.connection_state(table, &mut read, state, pos);
        if super::redstone::RedstoneWire::connected(table, connected, d ^ 1) {
            power
        } else {
            0
        }
    }

    /// `getDirectSignal`: wire's is its signal.
    pub(super) fn state_direct_signal(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        state: u16,
        d: usize,
    ) -> i32 {
        if self.table.block_of(state) == self.redstone.wire {
            self.state_signal(access, pos, state, d)
        } else {
            self.block_direct_signal(access, pos, state, d)
        }
    }

    /// `SignalGetter.getSignal(pos, d)`: a conductor also passes on the
    /// strongest direct signal into it.
    pub(super) fn level_signal(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        d: usize,
    ) -> i32 {
        let state = access.get(pos);
        let signal = self.state_signal(access, pos, state, d);
        if self.table.flag2(state, REDSTONE_CONDUCTOR) {
            signal.max(self.level_direct_signal_to(access, pos))
        } else {
            signal
        }
    }

    /// `getDirectSignalTo`.
    fn level_direct_signal_to(&self, access: &mut dyn BlockAccess, pos: [i32; 3]) -> i32 {
        let mut result = 0;
        for d in 0..6 {
            let neighbour = at(pos, d);
            let state = access.get(neighbour);
            result = result.max(self.state_direct_signal(access, neighbour, state, d));
            if result >= 15 {
                break;
            }
        }
        result
    }

    /// `SignalGetter.getControlInputSignal`: a diode's side input from the
    /// cell at `pos` toward `d` (only diodes count for a repeater).
    pub(super) fn control_input(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        d: usize,
        diodes_only: bool,
    ) -> i32 {
        let table = self.table.as_ref();
        let state = access.get(pos);
        let block = table.block_of(state);
        if diodes_only {
            if self.redstone.is_diode(block) {
                self.state_direct_signal(access, pos, state, d)
            } else {
                0
            }
        } else if block == self.redstone.redstone_block {
            15
        } else if block == self.redstone.wire {
            table
                .value(state, "power")
                .and_then(|p| p.parse().ok())
                .unwrap_or(0)
        } else if table.flag2(state, SIGNAL_SOURCE) {
            self.state_direct_signal(access, pos, state, d)
        } else {
            0
        }
    }

    /// `DiodeBlock.getAlternateSignal`: the stronger side input.
    pub(super) fn alternate_signal(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        state: u16,
        diodes_only: bool,
    ) -> i32 {
        let facing = super::components::facing(&self.table, state);
        let (clockwise, counter) = (CLOCKWISE[facing], COUNTER_CLOCKWISE[facing]);
        let a = self.control_input(access, at(pos, clockwise), clockwise, diodes_only);
        let b = self.control_input(access, at(pos, counter), counter, diodes_only);
        a.max(b)
    }

    /// `RepeaterBlock.isLocked`: a powered diode at either side.
    pub(super) fn repeater_locked(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        state: u16,
    ) -> bool {
        self.alternate_signal(access, pos, state, true) > 0
    }
}

/// `Direction.getClockWise` and `getCounterClockWise` of the horizontal
/// directions (by index; up and down map to themselves, unused).
pub(super) const CLOCKWISE: [usize; 6] = [0, 1, 5, 4, 2, 3];
pub(super) const COUNTER_CLOCKWISE: [usize; 6] = [0, 1, 4, 5, 3, 2];

impl<W: World> Engine<'_, W> {
    pub(super) fn power_facts(&self) -> Option<&PowerFacts> {
        self.rules.power.as_ref()
    }

    /// `SignalGetter.getSignal(pos, d)`.
    pub(super) fn level_signal(&mut self, pos: [i32; 3], d: usize) -> i32 {
        let rules = self.rules;
        rules.level_signal(&mut self.world, pos, d)
    }

    /// `hasSignal(pos, d)`.
    pub(super) fn has_signal(&mut self, pos: [i32; 3], d: usize) -> bool {
        self.level_signal(pos, d) > 0
    }

    /// `hasNeighborSignal`.
    pub(super) fn has_neighbor_signal(&mut self, pos: [i32; 3]) -> bool {
        (0..6).any(|d| self.level_signal(at(pos, d), d) > 0)
    }

    /// `state.getAnalogOutputSignal(level, pos, d)`: the facts' value, or
    /// the owner's block entity's; a chest under a conductor gives none
    /// (`ChestBlock.isBlockedChestByBlock`).
    pub(super) fn analog_signal(&mut self, pos: [i32; 3], state: u16) -> i32 {
        let Some(facts) = self.power_facts() else {
            return 0;
        };
        match facts.analog(state) {
            Analog::None => 0,
            Analog::Value(v) => v,
            Analog::Entity => {
                let table = self.rules.table.as_ref();
                if table.class_name(state).ends_with("ChestBlock") {
                    let above = self.world.get(at(pos, UP));
                    if self.rules.table.flag2(above, REDSTONE_CONDUCTOR) {
                        return 0;
                    }
                }
                self.world.container_signal(pos)
            }
        }
    }

    /// `hasAnalogOutputSignal`.
    pub(super) fn has_analog(&self, state: u16) -> bool {
        self.power_facts()
            .is_some_and(|f| f.analog(state) != Analog::None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_linear_track_wraps_its_period() {
        let track = Track {
            keyframes: vec![
                (133, 1.0),
                (11867, 1.0),
                (13670, 0.26666668),
                (22330, 0.26666668),
            ],
            bezier: None,
        };
        assert_eq!(track.sample(24000, 6000), 1.0);
        assert_eq!(track.sample(24000, 18000), 0.26666668);
        // Between 22330 and 133 + 24000 it climbs back.
        let dawn = track.sample(24000, 23_500);
        assert!(dawn > 0.26666668 && dawn < 1.0);
        assert_eq!(track.sample(24000, 24_000 + 6000), 1.0);
    }

    #[test]
    fn daylight_power_follows_the_sun_and_inverts() {
        assert_eq!(daylight_power(15, 0.0, false), 15);
        assert_eq!(daylight_power(0, 0.0, false), 0);
        assert_eq!(daylight_power(15, 0.0, true), 0);
        assert_eq!(daylight_power(4, 0.0, true), 11);
        // At sunset the sun stands at 90 degrees.
        assert!(daylight_power(15, 90.0, false) < 15);
    }
}
