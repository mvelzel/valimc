//! Silverfish (`Valimc.AI.Mobs.Silverfish`, vanilla's `Silverfish`):
//!
//! - **Goals**: floating, climbing out of powder snow, waking its friends,
//!   melee, and with nothing to do slipping into a stone block beside it
//!   (`Merge`) or wandering, preferring spots over stone; whoever hurt it
//!   (and its kind around) and the player as targets.
//! - **Friends** (`WakeFriends`): hurt by something (or by what always
//!   wakes them), a second later it breaks the infested blocks around it,
//!   nearest layers first, each one stopping the search by chance; each
//!   breaks into a silverfish while mobs may grief, else turns back to its
//!   stone (`{:wake_infested, cell, state, griefing}`).
//! - **Merging**: an infested block takes the place of the stone it slips
//!   into (`{:infest, cell, state}`) and it is gone.
//! - Its body faces its yaw (`tick` sets `yBodyRot`); its steps are events.
//!
//! Its own mind field (`SilverfishOwn`): the friends countdown a hurt
//! starts, absent until set as the Elixir's `own.friends`.

use super::entity;
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{floor, reduced};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    ClimbPowderSnow, Float, HurtByTarget, MeleeAttack, NearestAttackableTarget, RandomStroll,
    TargetKind,
};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::shapes;
use crate::mobs::ai::turn::Turn;
use crate::mobs::combat::{Event, Family, Hit};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Emission, Kind, KindMotion, Registered, Registration};
use crate::mobs::level::Level;
use crate::mobs::model::Body;
use crate::mobs::term::Value;
use std::sync::Arc;

pub const SILVERFISH: &str = "minecraft:silverfish";

/// A silverfish's own mind field.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SilverfishOwn {
    pub friends: Option<i64>,
}

/// Its stones and their infested forms: each pair's states
/// `(host first, infested first, count)`, the blocks having the same
/// properties.
#[derive(Debug, PartialEq)]
pub struct Infested {
    pairs: Vec<(u16, u16, u16)>,
    /// The infested blocks' registry ids.
    infested: Vec<u16>,
}

impl Infested {
    pub fn new(facts: &MobFacts) -> Infested {
        let blocks = &facts.blocks;
        let mut pairs = Vec::new();
        let mut infested = Vec::new();
        for (id, b) in blocks.blocks.iter().enumerate() {
            let Some(host) = b.name.strip_prefix("infested_") else {
                continue;
            };
            infested.push(id as u16);
            let Some(h) = blocks.id(host).and_then(|h| blocks.block(h)) else {
                continue;
            };
            if h.properties == b.properties {
                pairs.push((h.first, b.first, h.last - h.first + 1));
            }
        }
        Infested { pairs, infested }
    }

    /// `infestedStateByHost`: the infested form of a stone's state.
    pub fn of(&self, state: u16) -> Option<u16> {
        self.pairs
            .iter()
            .find(|&&(host, _, n)| (host..host + n).contains(&state))
            .map(|&(host, infested, _)| infested + (state - host))
    }

    /// `InfestedBlock.isCompatibleHostBlock`.
    pub fn host(&self, state: Option<u16>) -> bool {
        state.is_some_and(|s| self.of(s).is_some())
    }

    /// Whether a state is an infested block's.
    pub fn infested(&self, level: &Level, state: Option<u16>) -> bool {
        state
            .and_then(|s| level.facts.blocks.block_id(s))
            .is_some_and(|id| self.infested.contains(&id))
    }
}

/// The silverfish family.
pub struct Silverfish {
    types: [&'static str; 1],
    type_id: u16,
    blocks: Arc<Infested>,
    /// Damage types that always wake them.
    waking: Vec<i32>,
}

impl Silverfish {
    pub fn new(facts: &MobFacts) -> Result<Silverfish, String> {
        Ok(Silverfish {
            types: [SILVERFISH],
            type_id: entity(facts, SILVERFISH)?,
            blocks: Arc::new(Infested::new(facts)),
            waking: facts
                .tags
                .get(
                    "minecraft:damage_type",
                    "minecraft:always_triggers_silverfish",
                )
                .map(<[i32]>::to_vec)
                .unwrap_or_default(),
        })
    }

    /// `notify/2`: a hurt from something (or a damage type that always
    /// wakes them) starts its friends countdown, whether or not the hurt
    /// takes (a mind that thought only).
    fn notify(&self, body: &mut Body, hit: &Hit) {
        if hit.attacker.is_none() && !self.waking.contains(&(hit.source as i32)) {
            return;
        }
        let Some(state) = body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) else {
            return;
        };
        let own = &mut state.own;
        let friends = own
            .family::<SilverfishOwn>()
            .and_then(|o| o.friends)
            .unwrap_or(0);
        if friends == 0 {
            own.family = Some(Box::new(SilverfishOwn {
                friends: Some(reduced(20)),
            }));
        }
    }
}

fn friends(t: &Turn) -> i64 {
    t.mind
        .own
        .family::<SilverfishOwn>()
        .and_then(|o| o.friends)
        .unwrap_or(0)
}

impl Hooks for Silverfish {
    /// `getWalkTargetValue`: ten over a stone it may infest.
    fn walk_value(&self, t: &mut Turn, [x, y, z]: [i32; 3]) -> Option<f64> {
        self.blocks
            .host(t.level.block([x, y - 1, z]))
            .then_some(10.0)
    }
}

impl Family for Silverfish {
    fn hurt(&self, body: &mut Body, hit: &Hit, _events: &mut Vec<Event>) {
        self.notify(body, hit);
    }

    fn repelled(&self, body: &mut Body, hit: &Hit) {
        self.notify(body, hit);
    }
}

impl Kind for Silverfish {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Silverfish"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(1, "FloatGoal", JUMP, Float::new()),
                Registration::new(
                    1,
                    "ClimbOnTopOfPowderSnowGoal",
                    JUMP,
                    ClimbPowderSnow::new(),
                ),
                Registration::new(
                    3,
                    "SilverfishWakeUpFriendsGoal",
                    0,
                    WakeFriends {
                        blocks: Arc::clone(&self.blocks),
                    },
                ),
                Registration::new(
                    4,
                    "MeleeAttackGoal",
                    MOVE | LOOK,
                    MeleeAttack::new(1.0, false, false),
                ),
                Registration::new(
                    5,
                    "SilverfishMergeWithStoneGoal",
                    MOVE,
                    Merge {
                        stroll: RandomStroll::new(
                            1.0,
                            StrollOptions {
                                interval: 10,
                                ..StrollOptions::default()
                            },
                        ),
                        merge: None,
                        blocks: Arc::clone(&self.blocks),
                    },
                ),
            ],
            targets: vec![
                Registration::new(
                    1,
                    "HurtByTargetGoal",
                    TARGET,
                    HurtByTarget::new(true, vec![self.type_id], Vec::new()),
                ),
                Registration::new(
                    2,
                    "NearestAttackableTargetGoal",
                    TARGET,
                    NearestAttackableTarget::new(
                        TargetKind::Player,
                        None,
                        true,
                        TargetOptions::default(),
                    ),
                ),
            ],
        }
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            emission: Emission::Events,
            ..KindMotion::default()
        }
    }

    /// `tick` sets its body's yaw first.
    fn tick_start(&self, t: &mut Turn) {
        t.mind.body_yaw = t.yaw();
    }
}

// ## Goals

/// `SilverfishWakeUpFriendsGoal` (`Silverfish.WakeFriends`): while its
/// friends countdown runs, each update counts it down; at its end the
/// infested blocks within ten blocks around and five up and down wake,
/// layer by layer from its own outward, each stopping the search on a coin
/// flip.
#[derive(Clone, Debug, PartialEq)]
pub struct WakeFriends {
    blocks: Arc<Infested>,
}

/// The search order: 0, 1, -1, 2, -2, ...
fn order(radius: i32) -> impl Iterator<Item = i32> + Clone {
    std::iter::once(0).chain((1..=radius).flat_map(|d| [d, -d]))
}

impl WakeFriends {
    fn wake(&self, t: &mut Turn) {
        let [bx, by, bz] = t.block();
        for dy in order(5) {
            for dx in order(10) {
                for dz in order(10) {
                    let cell = [bx + dx, by + dy, bz + dz];
                    let state = t.level.block(cell);
                    if !self.blocks.infested(t.level, state) {
                        continue;
                    }
                    let state = state.unwrap_or(0);
                    let griefing = t.level.rules.mob_griefing;
                    t.effect(Effect::WakeInfested(Value::tuple([
                        Value::ivec3(cell.map(i64::from)),
                        Value::Int(state as i64),
                        Value::bool(griefing),
                    ])));
                    if t.boolean() {
                        return;
                    }
                }
            }
        }
    }
}

impl Goal for WakeFriends {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        friends(t) > 0
    }

    fn tick(&mut self, t: &mut Turn) {
        let n = friends(t) - 1;
        t.mind.own.family = Some(Box::new(SilverfishOwn { friends: Some(n) }));
        if n <= 0 {
            self.wake(t);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Silverfish.WakeFriends"
    }
}

/// `SilverfishMergeWithStoneGoal` (`Silverfish.Merge`): with no target and
/// nowhere to go, while mobs may grief, one update in five it picks a
/// direction; a stone it may infest that way (from half a block up) takes
/// it in: the block becomes infested and the silverfish is gone. Otherwise
/// it strolls as `RandomStrollGoal` (speed 1, interval 10).
#[derive(Clone, Debug, PartialEq)]
pub struct Merge {
    stroll: RandomStroll,
    merge: Option<([i32; 3], u16)>,
    blocks: Arc<Infested>,
}

impl Merge {
    fn pick(&self, t: &mut Turn) -> Option<([i32; 3], u16)> {
        if !t.level.rules.mob_griefing || t.int(reduced(10) as i32) != 0 {
            return None;
        }
        let d = t.int(6) as usize;
        let [dx, dy, dz] = shapes::step(d);
        let [x, y, z] = t.pos();
        let cell = [floor(x) + dx, floor(y + 0.5) + dy, floor(z) + dz];
        let state = t.level.block(cell);
        if self.blocks.host(state) {
            state.map(|s| (cell, s))
        } else {
            None
        }
    }
}

impl Goal for Merge {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if t.target().is_some() || !t.mind.navigation.done() {
            return false;
        }
        match self.pick(t) {
            Some(merge) => {
                self.merge = Some(merge);
                true
            }
            None => {
                self.merge = None;
                self.stroll.can_use(t)
            }
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match self.merge {
            None => self.stroll.can_continue(t),
            Some(_) => false,
        }
    }

    fn start(&mut self, t: &mut Turn) {
        match self.merge {
            None => self.stroll.start(t),
            Some((cell, host)) => {
                let state = self.blocks.of(host).unwrap_or(host);
                t.effect(Effect::Infest {
                    cell,
                    state: state as i32,
                });
                t.effect(Effect::Event(20));
                t.effect(Effect::Discard);
            }
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        if self.merge.is_none() {
            self.stroll.stop(t);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Silverfish.Merge"
    }
}
