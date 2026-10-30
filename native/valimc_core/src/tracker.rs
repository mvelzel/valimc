//! An entity's tracker (vanilla's `ServerEntity`, VMC-081i): what observers
//! were last sent of it (the position base, motion, ground flag, rotation and
//! head angle bytes) and, each tick its owner tracks it, the packets of what
//! changed, encoded once for every observer into the section's frame.
//!
//! The rules are `Valimc.Entity.Tracker.tick_body/2`'s: at the type's update
//! interval, or whenever its entity data changed, a body sends its motion
//! (when the type tracks it), then a relative move with its rotation, the
//! move or the rotation alone, or an absolute sync (every 400 updates, on a
//! ground change, or a move too far for a delta), then the changed data its
//! owner encoded, then its head's yaw. Every 60 ticks of an update the
//! position goes out even unchanged.
//!
//! A frame is a run of entries `<<entity id::32, packet id::16, size::32,
//! payload::binary-size(size)>>`, one per packet, each entity's in order.

use crate::wire::varint;

/// The clientbound play packet ids the tracker writes (`Packets.packet/2`'s).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PacketIds {
    pub add_entity: u16,
    pub motion: u16,
    pub position_sync: u16,
    pub move_pos: u16,
    pub move_pos_rot: u16,
    pub move_rot: u16,
    pub rotate_head: u16,
}

/// What an entity is now, as the tracker reads it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Seen {
    pub position: [f64; 3],
    pub yaw: f64,
    pub pitch: f64,
    pub head_yaw: f64,
    pub velocity: [f64; 3],
    pub on_ground: bool,
}

/// One entity's tracker.
#[derive(Clone, Debug, PartialEq)]
pub struct Tracker {
    pub base: [f64; 3],
    pub movement: [f64; 3],
    pub on_ground: bool,
    /// The yaw and pitch angle bytes sent.
    pub rotation: (u8, u8),
    pub head: u8,
    pub tick: u64,
    pub teleport_delay: u64,
    pub interval: u64,
    pub track_deltas: bool,
}

/// `ServerEntity`'s tolerance for an unchanged position (squared blocks).
const TOLERANCE: f64 = 7.6293945e-6;

impl Tracker {
    /// A tracker whose observers were sent the entity at `base` moving at
    /// `movement` (`Tracker.new_body/1`).
    pub fn new(
        base: [f64; 3],
        movement: [f64; 3],
        on_ground: bool,
        rotation: (u8, u8),
        head: u8,
        interval: i32,
        track_deltas: bool,
    ) -> Tracker {
        Tracker {
            base,
            movement,
            on_ground,
            rotation,
            head,
            tick: 0,
            teleport_delay: 0,
            interval: interval.max(1) as u64,
            track_deltas,
        }
    }

    /// One tick of the entity `id` seen as `seen`: appends its packets to
    /// `out` (`changes`, the owner's encoded data changes, already frame
    /// entries, forcing an update when not empty). Returns whether what a
    /// new observer is spawned with (the base, motion, rotation or head)
    /// changed.
    pub fn tick(
        &mut self,
        id: i32,
        seen: &Seen,
        changes: &[u8],
        ids: &PacketIds,
        out: &mut Vec<u8>,
    ) -> bool {
        let before = (self.base, self.movement, self.rotation, self.head);
        if self.tick.is_multiple_of(self.interval) || !changes.is_empty() {
            self.teleport_delay += 1;
            if self.track_deltas {
                self.motion(id, seen.velocity, ids, out);
            }
            self.move_body(id, seen, ids, out);
            out.extend_from_slice(changes);
            let head = angle(seen.head_yaw);
            if head != self.head {
                entry(out, id, ids.rotate_head, |p| {
                    varint(p, id as u32);
                    p.push(head);
                });
            }
            self.head = head;
        }
        self.tick += 1;
        before != (self.base, self.movement, self.rotation, self.head)
    }

    fn motion(&mut self, id: i32, velocity: [f64; 3], ids: &PacketIds, out: &mut Vec<u8>) {
        let diff = distance_sq(velocity, self.movement);
        let [vx, vy, vz] = velocity;
        if diff > 1.0e-7 || (diff > 0.0 && vx * vx + vy * vy + vz * vz == 0.0) {
            self.movement = velocity;
            entry(out, id, ids.motion, |p| {
                varint(p, id as u32);
                packed_velocity(p, velocity);
            });
        }
    }

    // `ServerEntity`'s move packet: a sync, a relative move (with the
    // rotation when it turned), the rotation alone, or nothing.
    fn move_body(&mut self, id: i32, seen: &Seen, ids: &PacketIds, out: &mut Vec<u8>) {
        let position = seen.position;
        let rotation = (angle(seen.yaw), angle(seen.pitch));
        let turned = rotation != self.rotation;
        let delta = [0, 1, 2].map(|i| encode(position[i]) - encode(self.base[i]));
        let moved = distance_sq(position, self.base) >= TOLERANCE || self.tick.is_multiple_of(60);
        let fits = delta.iter().all(|d| (-32768..=32767).contains(d));
        let ground = u8::from(seen.on_ground);
        if self.teleport_delay > 400 || self.on_ground != seen.on_ground || (moved && !fits) {
            self.on_ground = seen.on_ground;
            self.teleport_delay = 0;
            self.base = position;
            self.rotation = rotation;
            entry(out, id, ids.position_sync, |p| {
                varint(p, id as u32);
                // PositionPath.Type.LINEAR, then the final position.
                p.push(0);
                for v in position {
                    p.extend_from_slice(&v.to_be_bytes());
                }
                p.extend_from_slice(&(seen.yaw as f32).to_be_bytes());
                p.extend_from_slice(&(seen.pitch as f32).to_be_bytes());
                p.push(ground);
            });
        } else if moved {
            self.base = position;
            let (packet, rotate) = if turned {
                self.rotation = rotation;
                (ids.move_pos_rot, true)
            } else {
                (ids.move_pos, false)
            };
            entry(out, id, packet, |p| {
                varint(p, id as u32);
                p.push(ground);
                for d in delta {
                    p.extend_from_slice(&(d as i16).to_be_bytes());
                }
                if rotate {
                    p.push(rotation.0);
                    p.push(rotation.1);
                }
            });
        } else if turned {
            self.rotation = rotation;
            entry(out, id, ids.move_rot, |p| {
                varint(p, id as u32);
                p.push(ground);
                p.push(rotation.0);
                p.push(rotation.1);
            });
        }
    }
}

/// A frame entry of entity `id`: packet `packet` whose payload `write`
/// appends.
pub fn entry(out: &mut Vec<u8>, id: i32, packet: u16, write: impl FnOnce(&mut Vec<u8>)) {
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&packet.to_be_bytes());
    let at = out.len();
    out.extend_from_slice(&[0; 4]);
    write(out);
    let size = (out.len() - at - 4) as u32;
    out[at..at + 4].copy_from_slice(&size.to_be_bytes());
}

/// The spawn of a body (`ClientboundAddEntityPacket`, `EntityPackets.spawn/2`)
/// of registry type `ty` at `base` moving at `movement`, facing `seen`'s
/// rotation, with spawn data 0: the payload.
pub fn spawn_payload(
    id: i32,
    uuid: &[u8; 16],
    ty: u16,
    base: [f64; 3],
    movement: [f64; 3],
    seen: &Seen,
) -> Vec<u8> {
    let mut p = Vec::with_capacity(64);
    varint(&mut p, id as u32);
    p.extend_from_slice(uuid);
    varint(&mut p, u32::from(ty));
    for v in base {
        p.extend_from_slice(&v.to_be_bytes());
    }
    packed_velocity(&mut p, movement);
    p.push(angle(seen.pitch));
    p.push(angle(seen.yaw));
    p.push(angle(seen.head_yaw));
    varint(&mut p, 0);
    p
}

/// An angle in degrees as vanilla packs it (`Mth.packDegrees`).
pub fn angle(degrees: f64) -> u8 {
    (((degrees as f32) * 256.0f32 / 360.0f32).floor() as i64 & 255) as u8
}

// Vanilla's `VecDeltaCodec`: positions in 1/4096 blocks, rounded half up.
fn encode(value: f64) -> i64 {
    (value * 4096.0 + 0.5).floor() as i64
}

fn distance_sq(a: [f64; 3], b: [f64; 3]) -> f64 {
    let (dx, dy, dz) = (a[0] - b[0], a[1] - b[1], a[2] - b[2]);
    dx * dx + dy * dy + dz * dz
}

const MAX_VELOCITY: f64 = 17_179_869_183.0;

/// The 26.3 LP vector (`PackedVelocity.encode/1`).
pub fn packed_velocity(out: &mut Vec<u8>, v: [f64; 3]) {
    let [x, y, z] = v.map(|c| c.clamp(-MAX_VELOCITY, MAX_VELOCITY));
    let length = x.abs().max(y.abs().max(z.abs()));
    if length < 1.0 / 32766.0 {
        out.push(0);
        return;
    }
    let scale = length.ceil() as i64;
    let continuation = scale > 3;
    let markers = if continuation { (scale & 3) | 4 } else { scale };
    let pack = |c: f64| ((c / scale as f64 * 0.5 + 0.5) * 32766.0).round() as i64;
    let packed = markers | pack(x) << 3 | pack(y) << 18 | pack(z) << 33;
    out.push((packed & 255) as u8);
    out.push((packed >> 8 & 255) as u8);
    out.extend_from_slice(&((packed >> 16) as u32).to_be_bytes());
    if continuation {
        varint(out, (scale >> 2) as u32);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const IDS: PacketIds = PacketIds {
        add_entity: 1,
        motion: 2,
        position_sync: 3,
        move_pos: 4,
        move_pos_rot: 5,
        move_rot: 6,
        rotate_head: 7,
    };

    fn packets(frame: &[u8]) -> Vec<(i32, u16, Vec<u8>)> {
        let mut out = Vec::new();
        let mut rest = frame;
        while !rest.is_empty() {
            let id = i32::from_be_bytes(rest[0..4].try_into().unwrap());
            let packet = u16::from_be_bytes(rest[4..6].try_into().unwrap());
            let size = u32::from_be_bytes(rest[6..10].try_into().unwrap()) as usize;
            out.push((id, packet, rest[10..10 + size].to_vec()));
            rest = &rest[10 + size..];
        }
        out
    }

    fn seen(x: f64) -> Seen {
        Seen {
            position: [x, 64.0, 0.5],
            yaw: 0.0,
            pitch: 0.0,
            head_yaw: 0.0,
            velocity: [0.0; 3],
            on_ground: true,
        }
    }

    #[test]
    fn updates_at_the_interval_and_resends_every_sixty_ticks() {
        let mut t = Tracker::new([0.5, 64.0, 0.5], [0.0; 3], true, (0, 0), 0, 3, true);
        let mut out = Vec::new();
        // Tick 0 is an update: an unchanged position goes out (tick % 60 == 0).
        assert!(!t.tick(9, &seen(0.5), &[], &IDS, &mut out));
        assert_eq!(packets(&out), vec![(9, 4, vec![9, 1, 0, 0, 0, 0, 0, 0])]);
        out.clear();
        for _ in 1..60 {
            t.tick(9, &seen(0.5), &[], &IDS, &mut out);
        }
        assert!(out.is_empty());
        t.tick(9, &seen(0.5), &[], &IDS, &mut out);
        assert_eq!(packets(&out).len(), 1);
        out.clear();
        // A move between updates waits for the next one.
        assert!(!t.tick(9, &seen(0.75), &[], &IDS, &mut out));
        assert!(out.is_empty());
        t.tick(9, &seen(0.75), &[], &IDS, &mut out);
        assert!(t.tick(9, &seen(0.75), &[], &IDS, &mut out));
        assert_eq!(packets(&out), vec![(9, 4, vec![9, 1, 4, 0, 0, 0, 0, 0])]);
    }

    #[test]
    fn data_changes_force_an_update_and_sit_before_the_head() {
        let mut t = Tracker::new([0.5, 64.0, 0.5], [0.0; 3], true, (0, 0), 0, 3, true);
        let mut out = Vec::new();
        t.tick(9, &seen(0.5), &[], &IDS, &mut out);
        out.clear();
        let mut changes = Vec::new();
        entry(&mut changes, 9, 40, |p| p.push(7));
        let mut s = seen(0.5);
        s.head_yaw = 90.0;
        s.velocity = [0.1, 0.0, 0.0];
        assert!(t.tick(9, &s, &changes, &IDS, &mut out));
        let kinds: Vec<u16> = packets(&out).iter().map(|p| p.1).collect();
        assert_eq!(kinds, vec![2, 40, 7]);
        assert_eq!(t.head, 64);
    }

    #[test]
    fn syncs_on_ground_changes_far_moves_and_after_four_hundred_updates() {
        let mut t = Tracker::new([0.5, 64.0, 0.5], [0.0; 3], true, (0, 0), 0, 1, false);
        let mut out = Vec::new();
        let mut s = seen(0.5);
        s.on_ground = false;
        t.tick(9, &s, &[], &IDS, &mut out);
        assert_eq!(packets(&out)[0].1, 3);
        out.clear();
        t.tick(9, &seen(20.0), &[], &IDS, &mut out);
        assert_eq!(packets(&out)[0].1, 3);
        for _ in 0..401 {
            out.clear();
            t.tick(9, &seen(20.0), &[], &IDS, &mut out);
        }
        assert_eq!(packets(&out)[0].1, 3);
    }

    #[test]
    fn angles_and_velocities_encode_as_vanilla() {
        assert_eq!(angle(0.0), 0);
        assert_eq!(angle(90.0), 64);
        assert_eq!(angle(-90.0), 192);
        assert_eq!(angle(359.9), 255);
        let mut out = Vec::new();
        packed_velocity(&mut out, [0.0, 0.0, 0.0]);
        assert_eq!(out, vec![0]);
        out.clear();
        packed_velocity(&mut out, [10.0, -3.5, 0.25]);
        // A scale above 3 continues in a varint.
        assert_eq!(out.len(), 7);
    }
}
