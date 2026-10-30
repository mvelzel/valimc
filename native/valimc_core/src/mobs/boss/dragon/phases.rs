//! The dragon's phase decisions and their flight
//! (vanilla's `DragonPhaseInstance`s): holding
//! pattern, strafing a player, the landing approach, landing, the three
//! sitting phases (flaming, scanning, attacking), takeoff, charging a player,
//! dying and hovering. The owner gives the fixed arena graph, the podium,
//! the combat-eligible players and block and sight reads; effects ask it to
//! scan crystals, fire, breathe or set its health while dying.

use super::flight::{add, dot, normalize, scale, sub, Flight, RAD};
use super::paths;
use super::{Env, Player};
use crate::mobs::ai::fmath::{self, emax, emin, f};
use crate::mobs::random::LegacyRandom;
use crate::mobs::term::Value;

/// `(float) Math.PI`.
const PI: f64 = std::f64::consts::PI as f32 as f64;

/// What a phase asks of its actor (`state.effects`).
#[derive(Clone, Debug, PartialEq)]
pub enum PhaseEffect {
    /// Look for the nearest crystal (one tick in ten).
    ScanCrystals,
    /// The dying phase's health.
    Health(f64),
    /// A dragon fireball from `at` along `direction`.
    Fireball { at: [f64; 3], direction: [f64; 3] },
    /// Its breath on the podium.
    Flame([f64; 3]),
    /// Its breath ends.
    EndFlame,
}

/// `%Phases{}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Phases {
    pub phase: i64,
    pub flight: Flight,
    pub random: LegacyRandom,
    pub target: Option<[f64; 3]>,
    /// The phase it left and that phase's target.
    pub leaving: Option<(i64, Option<[f64; 3]>)>,
    /// The nodes still to fly through (None: no path).
    pub path: Option<Vec<[i64; 3]>>,
    /// Each circling phase's direction.
    pub clockwise: Vec<(i64, bool)>,
    pub ticks: i64,
    pub flames: i64,
    /// The player it strafes, as the term the Elixir keeps.
    pub attack: Option<Value>,
    pub charge: i64,
    pub first: bool,
    pub flame_live: bool,
    pub head_yaw: f64,
    pub pitch: f64,
    pub effects: Vec<PhaseEffect>,
}

impl Default for Phases {
    fn default() -> Phases {
        Phases {
            phase: 10,
            flight: Flight::default(),
            random: LegacyRandom { seed: 0 },
            target: None,
            leaving: None,
            path: None,
            clockwise: vec![(0, false), (1, false)],
            ticks: 0,
            flames: 0,
            attack: None,
            charge: 0,
            first: true,
            flame_live: false,
            head_yaw: 0.0,
            pitch: 0.0,
            effects: Vec::new(),
        }
    }
}

/// The id, position and height of an attack term.
pub fn attack_player(attack: &Value) -> Option<Player> {
    let m = attack.as_map()?;
    Some(Player {
        id: m.get_atom("id")?.as_int()?,
        position: m.get_atom("position")?.as_vec3()?,
        height: m.get_atom("height")?.as_number()?,
    })
}

fn bottom(p: [i64; 3]) -> [f64; 3] {
    [p[0] as f64 + 0.5, p[1] as f64, p[2] as f64 + 0.5]
}

fn center(p: [i64; 3]) -> [f64; 3] {
    [p[0] as f64 + 0.5, p[1] as f64 + 0.5, p[2] as f64 + 0.5]
}

fn floats(p: [i64; 3]) -> [f64; 3] {
    [p[0] as f64, p[1] as f64, p[2] as f64]
}

fn horizontal(v: [f64; 3]) -> [f64; 3] {
    [v[0], 0.0, v[2]]
}

fn distance(a: [f64; 3], b: [f64; 3]) -> f64 {
    let d = sub(a, b);
    dot(d, d)
}

/// `view/2`: the look vector of a yaw and pitch.
fn view(yaw: f64, pitch: f64) -> [f64; 3] {
    let x = f(pitch * RAD);
    let y = f(-yaw * RAD);
    [
        f(fmath::sin(y) * fmath::cos(x)),
        -fmath::sin(x),
        f(fmath::cos(y) * fmath::cos(x)),
    ]
}

fn wrap_double(value: f64) -> f64 {
    let mut value = value % 360.0;
    if value >= 180.0 {
        value -= 360.0;
    }
    if value < -180.0 {
        value += 360.0;
    }
    value
}

/// `ring/2`: an index on the outer ring, or else on the inner one.
fn ring(index: i64, outer: bool) -> usize {
    if outer {
        index.rem_euclid(12) as usize
    } else {
        (((index - 12) & 7) + 12) as usize
    }
}

impl Phases {
    /// `set/2`: enter a phase; its path and timers reset, its direction and
    /// flame count persist.
    pub fn set(&mut self, phase: i64) {
        if self.phase == phase {
            return;
        }
        if self.flame_live {
            self.effects.push(PhaseEffect::EndFlame);
        }
        self.leaving = Some((self.phase, self.target));
        self.phase = phase;
        self.target = None;
        self.path = None;
        self.ticks = 0;
        self.attack = None;
        self.charge = 0;
        self.first = true;
        self.flame_live = false;
        if phase == 5 {
            self.flames += 1;
        }
    }

    /// `tick/3`: one alive tick, with the crystal scan draw before the
    /// phase and a transition's second decision.
    pub fn tick(&mut self, env: &Env, no_ai: bool) {
        let scan = self.random.int(10);
        self.effects = if scan == 0 {
            vec![PhaseEffect::ScanCrystals]
        } else {
            Vec::new()
        };
        self.flight.begin_tick(no_ai);
        if no_ai {
            return;
        }
        let previous = self.phase;
        self.decide(env);
        let called = self.phase;
        if called != previous {
            self.decide(env);
        }
        // A second phase may transition again: the flight follows the last
        // phase that ran, with the target it left behind.
        let target = if self.phase == called {
            self.target
        } else {
            self.leaving.and_then(|(_, t)| t)
        };
        self.flight.advance(env.facts, target, called, env.wall);
    }

    /// `strafe/3`: strafe a combat-eligible player (`attack`, its term).
    pub fn strafe(&mut self, player: &Player, attack: Value, env: &Env) {
        self.set(1);
        self.attack = Some(attack);
        let [x, y, z] = player.position;
        let [dx, _, dz] = sub([x.floor(), y, z.floor()], self.flight.position);
        let last = [
            x.floor() as i64,
            (y + emin(f(0.4) + (dx * dx + dz * dz).sqrt() / 80.0 - 1.0, 10.0)).floor() as i64,
            z.floor() as i64,
        ];
        let from = self.closest(env);
        let to = paths::closest(&env.graph, player.position, env.crystals);
        self.route(env, from, to, Some(last));
        self.navigate();
    }

    fn decide(&mut self, env: &Env) {
        match self.phase {
            0 => self.holding(env),
            1 => self.strafing(env),
            2 => self.approach(env),
            3 => {
                if self.target.is_none() {
                    self.target = Some(bottom(env.podium));
                }
                if self.target_distance() < 1.0 {
                    self.flames = 0;
                    self.set(6);
                }
            }
            4 => self.takeoff(env),
            5 => self.flaming(env),
            6 => self.scanning(env),
            7 => {
                if self.ticks >= 40 {
                    self.set(5);
                } else {
                    self.ticks += 1;
                }
            }
            8 => {
                if self.target.is_none() || self.ticks >= 10 {
                    self.set(0);
                } else {
                    let retarget = self.retarget(env);
                    let ticks = self.ticks + if self.ticks > 0 { 1 } else { 0 };
                    self.ticks = ticks + if retarget { 1 } else { 0 };
                }
            }
            9 => {
                if self.target.is_none() {
                    self.target = Some(bottom(env.podium));
                }
                self.ticks += 1;
                let health = if self.retarget(env) { 0.0 } else { 1.0 };
                self.effects.push(PhaseEffect::Health(health));
            }
            10 if self.target.is_none() => self.target = Some(self.flight.position),
            _ => {}
        }
    }

    fn holding(&mut self, env: &Env) {
        if !self.retarget(env) {
            return;
        }
        if self.path.as_ref().is_some_and(Vec::is_empty) {
            let land = self.draw(env.crystals.unwrap_or(0) + 3);
            if land == 0 {
                self.set(2);
            } else {
                self.choose_strafe(env);
            }
        } else {
            self.circle(env);
        }
    }

    fn strafing(&mut self, env: &Env) {
        let Some(attack) = self.attack.clone() else {
            self.set(0);
            return;
        };
        let kept = attack_player(&attack);
        let id = kept.as_ref().map(|p| p.id);
        let (player, attack) = match env.players.iter().find(|p| Some(p.id) == id) {
            Some(p) => (p.clone(), p.term()),
            None => match kept {
                Some(p) => (p, attack),
                None => return,
            },
        };
        self.attack = Some(attack);
        let [x, y, z] = player.position;
        let [dx, _, dz] = sub(player.position, self.flight.position);
        if self.path.as_ref().is_some_and(Vec::is_empty) {
            self.target = Some([
                x,
                y + emin(f(0.4) + (dx * dx + dz * dz).sqrt() / 80.0 - 1.0, 10.0),
                z,
            ]);
        }
        if self.target_distance() < 100.0 || self.target_distance() > 22_500.0 {
            self.circle(env);
        }
        if distance(player.position, self.flight.position) < 4096.0 && env.visible(&player) {
            self.charge += 1;
            let angle = self.angle(&player);
            if self.charge >= 5 && (0.0..10.0).contains(&angle) {
                let head = self.flight.parts[0];
                let start = add(
                    head,
                    add(
                        scale(view(self.head_yaw, self.pitch), -1.0),
                        [0.0, env.facts.head_height() / 2.0 + 0.5, 0.0],
                    ),
                );
                let aim = add(player.position, [0.0, player.height / 2.0, 0.0]);
                self.effects.push(PhaseEffect::Fireball {
                    at: start,
                    direction: normalize(sub(aim, start)),
                });
                self.set(0);
            }
        } else {
            self.charge = (self.charge - 1).max(0);
        }
    }

    fn approach(&mut self, env: &Env) {
        if !self.retarget(env) {
            return;
        }
        if self.path.as_ref().is_none_or(Vec::is_empty) {
            let point = match env.nearest(floats(env.podium), None, false, None) {
                Some(player) => {
                    let [x, _, z] = player.position;
                    let [a, _, b] = normalize([x, 0.0, z]);
                    [-a * 40.0, 105.0, -b * 40.0]
                }
                None => [40.0, env.podium[1] as f64, 0.0],
            };
            let from = self.closest(env);
            let to = paths::closest(&env.graph, point, env.crystals);
            self.route(env, from, to, Some(env.podium));
        }
        self.navigate();
        if self.path.as_ref().is_some_and(Vec::is_empty) {
            self.set(3);
        }
    }

    fn takeoff(&mut self, env: &Env) {
        if !self.first && self.path.is_some() {
            if distance(self.flight.position, center(env.podium)) >= 100.0 {
                self.set(0);
            }
            return;
        }
        let [x, _, z] = self.head_look(env.podium);
        let target = paths::closest(&env.graph, [-x * 40.0, 105.0, -z * 40.0], env.crystals);
        let target = ring(target as i64, env.crystals.is_some_and(|c| c > 0));
        let from = self.closest(env);
        self.route(env, from, target, None);
        self.navigate();
        self.first = false;
    }

    fn flaming(&mut self, env: &Env) {
        self.ticks += 1;
        if self.ticks >= 200 {
            self.set(if self.flames >= 4 { 4 } else { 6 });
        } else if self.ticks == 10 {
            let head = self.flight.parts[0];
            let [hx, hy, hz] = head;
            let [dx, _, dz] = normalize(horizontal(sub(head, self.flight.position)));
            let x = hx + dx * 2.5;
            let z = hz + dz * 2.5;
            let initial = hy + env.facts.head_height() / 2.0;
            // Everything above the dimension's top is air: skipped
            // arithmetically, keeping the fractional sample.
            let above = ((initial - env.level.max_y as f64).ceil() as i64).max(0);
            let first = initial - above as f64;
            let y = env.flame_floor(x, first, z, initial).floor() as i64 + 1;
            self.flame_live = true;
            self.effects.push(PhaseEffect::Flame([x, y as f64, z]));
        }
    }

    fn scanning(&mut self, env: &Env) {
        self.ticks += 1;
        let player = env.nearest(self.flight.position, Some(20.0), true, Some(10.0));
        match player {
            Some(_) if self.ticks > 25 => self.set(7),
            Some(player) => self.scan_turn(&player),
            None if self.ticks >= 100 => {
                match env.nearest(self.flight.position, Some(150.0), true, None) {
                    Some(player) => {
                        self.set(8);
                        self.target = Some(player.position);
                    }
                    None => self.set(4),
                }
            }
            None => {}
        }
    }

    fn choose_strafe(&mut self, env: &Env) {
        let Some(player) = env.nearest(floats(env.podium), None, false, None) else {
            self.circle(env);
            return;
        };
        let bound = (distance(center(env.podium), player.position) / 512.0 + 2.0).trunc() as i64;
        let attack = if self.draw(bound) == 0 {
            true
        } else {
            self.draw(env.crystals.unwrap_or(0) + 2) == 0
        };
        if attack {
            let term = player.term();
            self.strafe(&player, term, env);
        } else {
            self.circle(env);
        }
    }

    fn clockwise(&self, phase: i64) -> bool {
        self.clockwise
            .iter()
            .find(|(p, _)| *p == phase)
            .is_some_and(|(_, c)| *c)
    }

    fn circle(&mut self, env: &Env) {
        if self.path.as_ref().is_none_or(Vec::is_empty) {
            let current = self.closest(env);
            let n = self.draw(8);
            let kept = self.clockwise(self.phase);
            let clockwise = if n == 0 { !kept } else { kept };
            let target =
                current as i64 + if n == 0 { 6 } else { 0 } + if clockwise { 1 } else { -1 };
            let outer = env
                .crystals
                .is_some_and(|c| if self.phase == 0 { c >= 0 } else { c > 0 });
            let phase = self.phase;
            match self.clockwise.iter_mut().find(|(p, _)| *p == phase) {
                Some(entry) => entry.1 = clockwise,
                None => {
                    self.clockwise.push((phase, clockwise));
                    self.clockwise.sort_by_key(|(p, _)| *p);
                }
            }
            self.route(env, current, ring(target, outer), None);
        }
        self.navigate();
    }

    fn closest(&self, env: &Env) -> usize {
        paths::closest(&env.graph, self.flight.position, env.crystals)
    }

    fn route(&mut self, env: &Env, from: usize, to: usize, last: Option<[i64; 3]>) {
        self.path = paths::find(&env.graph, from, to, env.crystals, last).map(|mut p| {
            p.remove(0);
            p
        });
    }

    fn navigate(&mut self) {
        let Some(path) = self.path.as_mut() else {
            return;
        };
        if path.is_empty() {
            return;
        }
        let [x, y, z] = path.remove(0);
        let offset = self.random.float() as f64;
        self.target = Some([x as f64, f(y as f64 + f(offset * 20.0)), z as f64]);
    }

    fn target_distance(&self) -> f64 {
        match self.target {
            None => 0.0,
            Some(t) => distance(t, self.flight.position),
        }
    }

    /// `retarget?/2`: near or far from its target, or collided (which its
    /// owner never reports; an oracle's scene does).
    fn retarget(&self, env: &Env) -> bool {
        let d = self.target_distance();
        d < 100.0 || d > 22_500.0 || env.collision
    }

    fn draw(&mut self, bound: i64) -> i64 {
        self.random.int(bound as i32) as i64
    }

    /// `angle/2`: degrees between its facing and the player, plus a half.
    fn angle(&self, player: &Player) -> f64 {
        let aim = normalize(horizontal(sub(player.position, self.flight.position)));
        let rad = f(self.flight.yaw * RAD);
        let direction = normalize([fmath::sin(rad), 0.0, -fmath::cos(rad)]);
        f(f(f(dot(direction, aim)).acos() * 180.0 / PI) + 0.5)
    }

    fn scan_turn(&mut self, player: &Player) {
        let angle = self.angle(player);
        if !(angle < 0.0 || angle > 10.0) {
            return;
        }
        let [dx, _, dz] = sub(player.position, self.flight.parts[0]);
        let delta = fmath::clamp(
            wrap_double(180.0 - fmath::atan2(dx, dz) * 180.0 / PI - self.flight.yaw),
            -100.0,
            100.0,
        );
        let speed = f(f((dx * dx + dz * dz).sqrt()) + 1.0);
        let turn =
            f(f(self.flight.turn * f(0.8))
                + f(f(delta) * f(f(f(0.7) / emin(speed, 40.0)) / speed)));
        self.flight.turn = turn;
        self.flight.yaw = f(self.flight.yaw + turn);
    }

    fn head_look(&self, podium: [i64; 3]) -> [f64; 3] {
        let distance = emax(
            f(f(distance(center(podium), self.flight.position).sqrt()) / 4.0),
            1.0,
        );
        let pitch = f(f(-f(6.0 / distance) * 1.5) * 5.0);
        view(self.head_yaw, pitch)
    }
}
