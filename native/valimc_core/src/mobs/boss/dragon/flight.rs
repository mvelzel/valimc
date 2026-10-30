//! One dragon's free flight and its eight part positions
//! (vanilla's `EnderDragon.aiStep` movement):
//! its height and yaw recorded before a phase picks the target, then one
//! steer toward it. The parts share its 64-sample history; they are boxes,
//! never separate owners.

use super::facts::{DragonFacts, PhaseFacts};
use crate::mobs::ai::fmath::{self, emax, emin, f};

/// `(float) Math.PI / 180`.
pub const RAD: f64 = (std::f64::consts::PI / 180.0) as f32 as f64;
/// `180 / (float) Math.PI`, rounded.
pub const DEG: f64 = (180.0 / (std::f64::consts::PI as f32 as f64)) as f32 as f64;

/// `%Flight{}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Flight {
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub yaw: f64,
    pub turn: f64,
    /// `{head, samples}`: 64 `(y, yaw)` samples, `head` the latest.
    pub history: Option<(i64, Vec<(f64, f64)>)>,
    pub parts: [[f64; 3]; 8],
}

impl Default for Flight {
    fn default() -> Flight {
        Flight {
            position: [0.0; 3],
            velocity: [0.0; 3],
            yaw: 0.0,
            turn: 0.0,
            history: None,
            parts: [[0.0; 3]; 8],
        }
    }
}

pub fn add(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

pub fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

pub fn scale(a: [f64; 3], n: f64) -> [f64; 3] {
    [a[0] * n, a[1] * n, a[2] * n]
}

pub fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// `normalize/1`: zero below a length of 1.0e-5.
pub fn normalize(v: [f64; 3]) -> [f64; 3] {
    let length = dot(v, v).sqrt();
    if length < 1.0e-5 {
        [0.0; 3]
    } else {
        [v[0] / length, v[1] / length, v[2] / length]
    }
}

impl Flight {
    /// `begin_tick/2`: its yaw wrapped and the pre-phase sample recorded
    /// (none without AI).
    pub fn begin_tick(&mut self, no_ai: bool) {
        self.yaw = fmath::wrap(self.yaw);
        if !no_ai {
            self.record();
        }
    }

    fn record(&mut self) {
        let sample = (self.position[1], self.yaw);
        match &mut self.history {
            None => self.history = Some((0, vec![sample; 64])),
            Some((head, samples)) => {
                *head = (*head + 1).rem_euclid(64);
                samples[*head as usize] = sample;
            }
        }
    }

    /// `advance/4`: toward `target` and its parts placed from the history.
    pub fn advance(
        &mut self,
        facts: &DragonFacts,
        target: Option<[f64; 3]>,
        phase: i64,
        wall: bool,
    ) {
        let profile = facts.phase(phase);
        if let Some(target) = target {
            self.steer(target, profile, wall);
        }
        self.parts = self.place(profile.sitting);
    }

    fn steer(&mut self, target: [f64; 3], profile: PhaseFacts, wall: bool) {
        let [dx, dy0, dz] = sub(target, self.position);
        let distance = dx * dx + dy0 * dy0 + dz * dz;
        let horizontal = (dx * dx + dz * dz).sqrt();
        let dy = if horizontal > 0.0 {
            fmath::clamp(dy0 / horizontal, -profile.speed, profile.speed)
        } else {
            dy0
        };
        let [vx, vy, vz] = self.velocity;
        let vy = vy + dy * 0.01;
        let radians = f(self.yaw * RAD);
        let direction = normalize([fmath::sin(radians), vy, -fmath::cos(radians)]);
        let aim = normalize([dx, target[1] - self.position[1], dz]);
        let alignment = emax(f(f(f(dot(direction, aim)) + 0.5) / 1.5), 0.0);
        let near = 1.0e-5_f32 as f64;
        let (yaw, turn) = if dx.abs() > near || dz.abs() > near {
            let delta = fmath::clamp(
                fmath::wrap(f(f(180.0 - f(f(fmath::atan2(dx, dz)) * DEG)) - self.yaw)),
                -50.0,
                50.0,
            );
            let rotation_speed = f(f((vx * vx + vz * vz).sqrt()) + 1.0);
            let limited = emin(rotation_speed, 40.0);
            let gain = if profile.landing {
                f(limited / rotation_speed)
            } else {
                f(f(f(0.7) / limited) / rotation_speed)
            };
            let turn = f(f(self.turn * f(0.8)) + f(delta * gain));
            (f(self.yaw + f(turn * f(0.1))), turn)
        } else {
            (self.yaw, self.turn)
        };
        let span = f(2.0 / (distance + 1.0));
        let speed = f(f(0.06) * f(f(alignment * span) + f(1.0 - span)));
        let radians = f(yaw * RAD);
        let velocity = [
            vx + speed * fmath::sin(radians),
            vy,
            vz - speed * fmath::cos(radians),
        ];
        let factor = if wall { f(0.8) } else { 1.0 };
        self.position = add(self.position, scale(velocity, factor));
        let slide = 0.8 + 0.15 * (dot(normalize(velocity), direction) + 1.0) / 2.0;
        self.velocity = [
            velocity[0] * slide,
            velocity[1] * f(0.91),
            velocity[2] * slide,
        ];
        self.yaw = yaw;
        self.turn = turn;
    }

    fn sample(&self, delay: i64) -> (f64, f64) {
        match &self.history {
            Some((head, samples)) => samples[(head - delay).rem_euclid(64) as usize],
            None => (0.0, 0.0),
        }
    }

    /// `parts/2`: head, neck, body, three tail segments and two wings.
    fn place(&self, sitting: bool) -> [[f64; 3]; 8] {
        let (y5, yaw5) = self.sample(5);
        let (y10, _) = self.sample(10);
        let (y0, _) = self.sample(0);
        let tilt = f(f(f(y5 - y10) * 10.0) * RAD);
        let st = fmath::sin(tilt);
        let ct = fmath::cos(tilt);
        let rad = f(self.yaw * RAD);
        let s = fmath::sin(rad);
        let c = fmath::cos(rad);
        let bend = f(rad - f(self.turn * f(0.01)));
        let sb = fmath::sin(bend);
        let cb = fmath::cos(bend);
        let offset = if sitting { -1.0 } else { f(y5 - y0) };
        let head = [
            f(f(sb * 6.5) * ct),
            f(offset + f(st * 6.5)),
            f(f(-cb * 6.5) * ct),
        ];
        let neck = [
            f(f(sb * 5.5) * ct),
            f(offset + f(st * 5.5)),
            f(f(-cb * 5.5) * ct),
        ];
        let tail = |i: i64| {
            let (y, yaw) = self.sample(12 + i * 2);
            let turn = f(rad + f(fmath::wrap(f(yaw - yaw5)) * RAD));
            let length = (i + 1) as f64 * 2.0;
            [
                f(-f(f(s * 1.5) + f(fmath::sin(turn) * length)) * ct),
                y - y5 - f(f(length + 1.5) * st) + 1.5,
                f(f(f(c * 1.5) + f(fmath::cos(turn) * length)) * ct),
            ]
        };
        let offsets = [
            head,
            neck,
            [f(s * 0.5), 0.0, f(-c * 0.5)],
            tail(0),
            tail(1),
            tail(2),
            [f(c * 4.5), 2.0, f(s * 4.5)],
            [f(c * -4.5), 2.0, f(s * -4.5)],
        ];
        offsets.map(|o| add(self.position, o))
    }

    /// `boxes/1`: the eight part boxes in the client's implicit network-id
    /// order.
    pub fn boxes(&self, facts: &DragonFacts) -> [[f64; 6]; 8] {
        let mut out = [[0.0; 6]; 8];
        for (i, ((width, height), [x, y, z])) in facts.parts.iter().zip(self.parts).enumerate() {
            let half = f(width / 2.0);
            out[i] = [x - half, y, z - half, x + half, y + height, z + half];
        }
        out
    }
}
