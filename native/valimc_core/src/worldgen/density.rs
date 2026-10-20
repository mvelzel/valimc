//! Density functions as data (VMC-023c): vanilla's `worldgen/density_function`
//! types parsed from generated facts, with the two properties vanilla's
//! compiler reads before sampling: the axes a function depends on
//! (`domainAxes`) and its value range (`range`).
//!
//! Functions compare by value, as vanilla's records do (floats by bit pattern,
//! as `Float.compare`); references to registry entries compare by identifier.
//! The compiler deduplicates caches and spline coordinates by this equality.

use std::hash::{Hash, Hasher};

use super::interval::{Interval, INFINITE, NAI};
use super::java::{clamp, fmax, fmin};
use super::json::Json;

/// A float compared like Java's `Float.compare` (bit patterns, NaNs equal).
#[derive(Clone, Copy, Debug)]
pub struct F32(pub f32);

impl PartialEq for F32 {
    fn eq(&self, other: &Self) -> bool {
        self.0.to_bits() == other.0.to_bits() || (self.0.is_nan() && other.0.is_nan())
    }
}

impl Eq for F32 {}

impl Hash for F32 {
    fn hash<H: Hasher>(&self, state: &mut H) {
        if self.0.is_nan() {
            f32::NAN.to_bits()
        } else {
            self.0.to_bits()
        }
        .hash(state)
    }
}

/// A double compared like Java's `Double.compare`.
#[derive(Clone, Copy, Debug)]
pub struct F64(pub f64);

impl PartialEq for F64 {
    fn eq(&self, other: &Self) -> bool {
        self.0.to_bits() == other.0.to_bits() || (self.0.is_nan() && other.0.is_nan())
    }
}

impl Eq for F64 {}

impl Hash for F64 {
    fn hash<H: Hasher>(&self, state: &mut H) {
        if self.0.is_nan() {
            f64::NAN.to_bits()
        } else {
            self.0.to_bits()
        }
        .hash(state)
    }
}

pub const AXIS_X: u8 = 1;
pub const AXIS_Y: u8 = 2;
pub const AXIS_Z: u8 = 4;
pub const ALL_AXES: u8 = 7;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Axis {
    X,
    Y,
    Z,
}

impl Axis {
    pub fn bit(self) -> u8 {
        match self {
            Axis::X => AXIS_X,
            Axis::Y => AXIS_Y,
            Axis::Z => AXIS_Z,
        }
    }

    pub fn choose(self, x: i32, y: i32, z: i32) -> i32 {
        match self {
            Axis::X => x,
            Axis::Y => y,
            Axis::Z => z,
        }
    }

    fn parse(json: &Json) -> Result<Axis, String> {
        match json.as_str()? {
            "x" => Ok(Axis::X),
            "y" => Ok(Axis::Y),
            "z" => Ok(Axis::Z),
            other => Err(format!("unknown axis {other}")),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Tiling {
    ClampToEdge,
    Repeat,
    MirroredRepeat,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Metric {
    Euclidean,
    EuclideanSquared,
    Manhattan,
    Chebyshev,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ShiftKind {
    /// `shift_a`: noise at (x/4, 0, z/4).
    A,
    /// `shift_b`: noise at (z/4, x/4, 0).
    B,
    /// `shift`: noise at (x/4, y/4, z/4).
    Xyz,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Simple {
    BlendAlpha,
    BlendOffset,
    Beardifier,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Unary {
    Abs,
    Square,
    Cube,
    Sqrt,
    HalfNegative,
    QuarterNegative,
    Reciprocal,
    Negate,
    Squeeze,
    Log,
    Sign,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Binary {
    Add,
    Sub,
    Mul,
    Div,
    Min,
    Max,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Df {
    Constant(F32),
    /// A `worldgen/density_function` registry entry.
    Ref(String),
    Simple(Simple),
    Noise {
        noise: String,
        xz_scale: F64,
        y_scale: F64,
        shift: Box<[Df; 3]>,
    },
    EndIslands,
    Distance {
        point: [i32; 3],
        metric: Metric,
    },
    Gradient {
        axis: Axis,
        tiling: Tiling,
        from: i32,
        to: i32,
        from_value: F32,
        to_value: F32,
    },
    Shift {
        kind: ShiftKind,
        noise: String,
    },
    Unary(Unary, Box<Df>),
    Binary(Binary, Box<Df>, Box<Df>),
    Spline(Box<Spline>),
    /// Alpha, first, second.
    Lerp(Box<[Df; 3]>),
    Clamp {
        input: Box<Df>,
        min: F32,
        max: F32,
    },
    RangeChoice {
        input: Box<Df>,
        min: F32,
        max: F32,
        in_range: Box<Df>,
        out_of_range: Box<Df>,
    },
    IntervalSelect {
        input: Box<Df>,
        thresholds: Vec<F32>,
        functions: Vec<Df>,
    },
    Cache(Box<Df>),
    BlendDensity(Box<Df>),
    Interpolated {
        input: Box<Df>,
        xz: i32,
        y: i32,
    },
    Slice {
        axis: Axis,
        coordinate: i32,
        input: Box<Df>,
    },
    FindTopSurface {
        density: Box<Df>,
        upper: Box<Df>,
        lower: i32,
        cell: i32,
    },
    /// `old_blended_noise`: XZ scale, Y scale, XZ factor, Y factor, smear.
    Blended([F64; 5]),
    /// A cache the compiler has prepared (vanilla's `PreparedCache`).
    Prepared(usize),
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Spline {
    Constant(F32),
    Multipoint {
        coordinate: Df,
        locations: Vec<F32>,
        values: Vec<Spline>,
        derivatives: Vec<F32>,
    },
}

pub fn zero() -> Df {
    Df::Constant(F32(0.0))
}

/// Identifiers default to the `minecraft` namespace.
pub fn identifier(text: &str) -> String {
    if text.contains(':') {
        text.to_string()
    } else {
        format!("minecraft:{text}")
    }
}

fn float(json: &Json, key: &str) -> Result<F32, String> {
    Ok(F32(json.field(key)?.as_f64()? as f32))
}

fn double(json: &Json, key: &str) -> Result<F64, String> {
    Ok(F64(json.field(key)?.as_f64()?))
}

fn int(json: &Json, key: &str) -> Result<i32, String> {
    json.field(key)?.as_i32()
}

fn child(json: &Json, key: &str) -> Result<Box<Df>, String> {
    Ok(Box::new(Df::parse(json.field(key)?)?))
}

fn noise_id(json: &Json) -> Result<String, String> {
    match json.field("noise")? {
        Json::String(id) => Ok(identifier(id)),
        _ => Err("inline noise parameters are not supported".into()),
    }
}

impl Df {
    pub fn parse(json: &Json) -> Result<Df, String> {
        let fields = match json {
            Json::String(id) => return Ok(Df::Ref(identifier(id))),
            Json::Number(n) => return Ok(Df::Constant(F32(*n as f32))),
            Json::Object(_) => json,
            other => return Err(format!("not a density function: {other:?}")),
        };
        let kind = identifier(fields.field("type")?.as_str()?);
        let name = kind
            .strip_prefix("minecraft:")
            .ok_or_else(|| format!("unknown density function type {kind}"))?;
        let unary = |op| Ok(Df::Unary(op, child(fields, "input")?));
        let binary = |op| {
            Ok(Df::Binary(
                op,
                child(fields, "left")?,
                child(fields, "right")?,
            ))
        };
        match name {
            "constant" => Ok(Df::Constant(float(fields, "value")?)),
            "blend_alpha" => Ok(Df::Simple(Simple::BlendAlpha)),
            "blend_offset" => Ok(Df::Simple(Simple::BlendOffset)),
            "beardifier" => Ok(Df::Simple(Simple::Beardifier)),
            "noise" => {
                let shift = |key| match fields.get(key) {
                    Some(json) => Df::parse(json),
                    None => Ok(zero()),
                };
                Ok(Df::Noise {
                    noise: noise_id(fields)?,
                    xz_scale: double(fields, "xz_scale")?,
                    y_scale: double(fields, "y_scale")?,
                    shift: Box::new([shift("shift_x")?, shift("shift_y")?, shift("shift_z")?]),
                })
            }
            "end_outer_islands" => Ok(Df::EndIslands),
            "distance_to_point" => {
                let p = fields.field("point")?.as_array()?;
                if p.len() != 3 {
                    return Err("distance_to_point needs three coordinates".into());
                }
                Ok(Df::Distance {
                    point: [p[0].as_i32()?, p[1].as_i32()?, p[2].as_i32()?],
                    metric: match fields.field("metric")?.as_str()? {
                        "euclidean" => Metric::Euclidean,
                        "euclidean_squared" => Metric::EuclideanSquared,
                        "manhattan" => Metric::Manhattan,
                        "chebyshev" => Metric::Chebyshev,
                        other => return Err(format!("unknown metric {other}")),
                    },
                })
            }
            "gradient" => {
                let tiling = match fields.get("tiling") {
                    None => Tiling::ClampToEdge,
                    Some(t) => match t.as_str()? {
                        "clamp_to_edge" => Tiling::ClampToEdge,
                        "repeat" => Tiling::Repeat,
                        "mirrored_repeat" => Tiling::MirroredRepeat,
                        other => return Err(format!("unknown tiling {other}")),
                    },
                };
                let (from, to) = (
                    int(fields, "from_coordinate")?,
                    int(fields, "to_coordinate")?,
                );
                if from == to {
                    return Err("gradient from_coordinate equals to_coordinate".into());
                }
                Ok(Df::Gradient {
                    axis: Axis::parse(fields.field("axis")?)?,
                    tiling,
                    from,
                    to,
                    from_value: float(fields, "from_value")?,
                    to_value: float(fields, "to_value")?,
                })
            }
            "shift_a" | "shift_b" | "shift" => Ok(Df::Shift {
                kind: match name {
                    "shift_a" => ShiftKind::A,
                    "shift_b" => ShiftKind::B,
                    _ => ShiftKind::Xyz,
                },
                noise: noise_id(fields)?,
            }),
            "abs" => unary(Unary::Abs),
            "square" => unary(Unary::Square),
            "cube" => unary(Unary::Cube),
            "sqrt" => unary(Unary::Sqrt),
            "half_negative" => unary(Unary::HalfNegative),
            "quarter_negative" => unary(Unary::QuarterNegative),
            "reciprocal" => unary(Unary::Reciprocal),
            "negate" => unary(Unary::Negate),
            "squeeze" => unary(Unary::Squeeze),
            "log" => unary(Unary::Log),
            "sign" => unary(Unary::Sign),
            "add" => binary(Binary::Add),
            "sub" => binary(Binary::Sub),
            "mul" => binary(Binary::Mul),
            "div" => binary(Binary::Div),
            "min" => binary(Binary::Min),
            "max" => binary(Binary::Max),
            "spline" => Ok(Df::Spline(Box::new(Spline::parse(
                fields.field("spline")?,
            )?))),
            "lerp" => Ok(Df::Lerp(Box::new([
                Df::parse(fields.field("alpha")?)?,
                Df::parse(fields.field("first")?)?,
                Df::parse(fields.field("second")?)?,
            ]))),
            "clamp" => {
                let (min, max) = (float(fields, "min")?, float(fields, "max")?);
                if max.0 < min.0 {
                    return Err("clamp max below min".into());
                }
                Ok(Df::Clamp {
                    input: child(fields, "input")?,
                    min,
                    max,
                })
            }
            "range_choice" => Ok(Df::RangeChoice {
                input: child(fields, "input")?,
                min: float(fields, "min_inclusive")?,
                max: float(fields, "max_exclusive")?,
                in_range: child(fields, "when_in_range")?,
                out_of_range: child(fields, "when_out_of_range")?,
            }),
            "interval_select" => {
                let thresholds = fields
                    .field("thresholds")?
                    .as_array()?
                    .iter()
                    .map(|t| Ok(F32(t.as_f64()? as f32)))
                    .collect::<Result<Vec<_>, String>>()?;
                let functions = fields
                    .field("functions")?
                    .as_array()?
                    .iter()
                    .map(Df::parse)
                    .collect::<Result<Vec<_>, String>>()?;
                if thresholds.len() + 1 != functions.len()
                    || thresholds.windows(2).any(|w| w[1].0 < w[0].0)
                {
                    return Err(
                        "interval_select needs ordered thresholds, one fewer than functions".into(),
                    );
                }
                Ok(Df::IntervalSelect {
                    input: child(fields, "input")?,
                    thresholds,
                    functions,
                })
            }
            "cache" => Ok(Df::Cache(child(fields, "input")?)),
            "blend_density" => Ok(Df::BlendDensity(child(fields, "input")?)),
            "interpolated" => {
                let (xz, y) = (int(fields, "cell_size_xz")?, int(fields, "cell_size_y")?);
                if xz <= 0 || y <= 0 {
                    return Err("interpolated cell sizes must be positive".into());
                }
                Ok(Df::Interpolated {
                    input: child(fields, "input")?,
                    xz,
                    y,
                })
            }
            "slice" => Ok(Df::Slice {
                axis: Axis::parse(fields.field("axis")?)?,
                coordinate: int(fields, "coordinate")?,
                input: child(fields, "input")?,
            }),
            "find_top_surface" => {
                let cell = int(fields, "cell_height")?;
                if cell <= 0 {
                    return Err("find_top_surface cell height must be positive".into());
                }
                Ok(Df::FindTopSurface {
                    density: child(fields, "density")?,
                    upper: child(fields, "upper_bound")?,
                    lower: int(fields, "lower_bound")?,
                    cell,
                })
            }
            "old_blended_noise" => Ok(Df::Blended([
                double(fields, "xz_scale")?,
                double(fields, "y_scale")?,
                double(fields, "xz_factor")?,
                double(fields, "y_factor")?,
                double(fields, "smear_scale_multiplier")?,
            ])),
            other => Err(format!(
                "unsupported density function type minecraft:{other}"
            )),
        }
    }

    pub fn is_zero(&self) -> bool {
        *self == zero()
    }

    /// The function with each child replaced by `f(child)`, in vanilla's
    /// `rewriteChildren` order.
    pub fn map_children(&self, f: &mut dyn FnMut(&Df) -> Result<Df, String>) -> Result<Df, String> {
        let mut b = |d: &Df| f(d).map(Box::new);
        Ok(match self {
            Df::Noise {
                noise,
                xz_scale,
                y_scale,
                shift,
            } => {
                let [x, y, z] = &**shift;
                let (x, y, z) = (*b(x)?, *b(y)?, *b(z)?);
                Df::Noise {
                    noise: noise.clone(),
                    xz_scale: *xz_scale,
                    y_scale: *y_scale,
                    shift: Box::new([x, y, z]),
                }
            }
            Df::Unary(op, input) => Df::Unary(*op, b(input)?),
            Df::Binary(op, l, r) => {
                let l = b(l)?;
                Df::Binary(*op, l, b(r)?)
            }
            Df::Spline(spline) => Df::Spline(Box::new(spline.map_coordinates(&mut |c| f(c))?)),
            Df::Lerp(args) => {
                let [a, x, y] = &**args;
                let (a, x, y) = (*b(a)?, *b(x)?, *b(y)?);
                Df::Lerp(Box::new([a, x, y]))
            }
            Df::Clamp { input, min, max } => Df::Clamp {
                input: b(input)?,
                min: *min,
                max: *max,
            },
            Df::RangeChoice {
                input,
                min,
                max,
                in_range,
                out_of_range,
            } => {
                let input = b(input)?;
                let in_range = b(in_range)?;
                Df::RangeChoice {
                    input,
                    min: *min,
                    max: *max,
                    in_range,
                    out_of_range: b(out_of_range)?,
                }
            }
            Df::IntervalSelect {
                input,
                thresholds,
                functions,
            } => {
                let input = b(input)?;
                let functions = functions
                    .iter()
                    .map(&mut *f)
                    .collect::<Result<Vec<_>, String>>()?;
                Df::IntervalSelect {
                    input,
                    thresholds: thresholds.clone(),
                    functions,
                }
            }
            Df::Cache(input) => Df::Cache(b(input)?),
            Df::BlendDensity(input) => Df::BlendDensity(b(input)?),
            Df::Interpolated { input, xz, y } => Df::Interpolated {
                input: b(input)?,
                xz: *xz,
                y: *y,
            },
            Df::Slice {
                axis,
                coordinate,
                input,
            } => Df::Slice {
                axis: *axis,
                coordinate: *coordinate,
                input: b(input)?,
            },
            Df::FindTopSurface {
                density,
                upper,
                lower,
                cell,
            } => {
                let density = b(density)?;
                Df::FindTopSurface {
                    density,
                    upper: b(upper)?,
                    lower: *lower,
                    cell: *cell,
                }
            }
            leaf => leaf.clone(),
        })
    }

    /// The axes the function's value depends on (bits `AXIS_X`, `AXIS_Y`,
    /// `AXIS_Z`).
    pub fn axes(&self, env: &dyn Env) -> Result<u8, String> {
        Ok(match self {
            Df::Constant(_) => 0,
            Df::Ref(id) => env.function(id)?.axes(env)?,
            Df::Simple(Simple::Beardifier) => ALL_AXES,
            Df::Simple(_) => AXIS_X | AXIS_Z,
            Df::Noise {
                xz_scale,
                y_scale,
                shift,
                ..
            } => {
                let mut axes = ALL_AXES;
                if y_scale.0 == 0.0 {
                    axes &= !AXIS_Y;
                }
                if xz_scale.0 == 0.0 {
                    axes &= !(AXIS_X | AXIS_Z);
                }
                axes | shift[0].axes(env)? | shift[1].axes(env)? | shift[2].axes(env)?
            }
            Df::EndIslands => AXIS_X | AXIS_Z,
            Df::Distance { .. } | Df::Blended(_) => ALL_AXES,
            Df::Gradient { axis, .. } => axis.bit(),
            Df::Shift { kind, .. } => match kind {
                ShiftKind::Xyz => ALL_AXES,
                _ => AXIS_X | AXIS_Z,
            },
            Df::Unary(_, input)
            | Df::Clamp { input, .. }
            | Df::Cache(input)
            | Df::BlendDensity(input)
            | Df::Interpolated { input, .. } => input.axes(env)?,
            Df::Binary(_, l, r) => l.axes(env)? | r.axes(env)?,
            Df::Spline(spline) => {
                let mut axes = 0;
                spline.for_each_coordinate(&mut |c| {
                    axes |= c.axes(env)?;
                    Ok(())
                })?;
                axes
            }
            Df::Lerp(args) => args[0].axes(env)? | args[1].axes(env)? | args[2].axes(env)?,
            Df::RangeChoice {
                input,
                in_range,
                out_of_range,
                ..
            } => input.axes(env)? | in_range.axes(env)? | out_of_range.axes(env)?,
            Df::IntervalSelect {
                input, functions, ..
            } => {
                let mut axes = input.axes(env)?;
                for f in functions {
                    axes |= f.axes(env)?;
                }
                axes
            }
            Df::Slice { axis, input, .. } => input.axes(env)? & !axis.bit(),
            Df::FindTopSurface { density, upper, .. } => {
                (density.axes(env)? | upper.axes(env)?) & !AXIS_Y
            }
            Df::Prepared(i) => env.prepared(*i).1,
        })
    }

    /// The range of values the function can take (vanilla's `range()`).
    pub fn range(&self, env: &dyn Env) -> Result<Interval, String> {
        Ok(match self {
            Df::Constant(v) => Interval::exact(v.0),
            Df::Ref(id) => env.function(id)?.range(env)?,
            Df::Simple(Simple::BlendAlpha) => Interval::of(0.0, 1.0),
            Df::Simple(_) => INFINITE,
            Df::Noise { noise, .. } => Interval::symmetric(env.noise_range(noise)?),
            Df::EndIslands => Interval::of(-0.84375, 0.5625),
            Df::Distance { .. } => Interval::of(0.0, f32::INFINITY),
            Df::Gradient {
                from_value,
                to_value,
                ..
            } => Interval::encapsulating_values(from_value.0, to_value.0),
            Df::Shift { noise, .. } => Interval::mul(
                Interval::symmetric(env.noise_range(noise)?),
                Interval::exact(4.0),
            ),
            Df::Unary(op, input) => unary_range(*op, input.range(env)?),
            Df::Binary(op, l, r) => {
                let (l, r) = (l.range(env)?, r.range(env)?);
                match op {
                    Binary::Add => Interval::add(l, r),
                    Binary::Sub => Interval::sub(l, r),
                    Binary::Mul => Interval::mul(l, r),
                    Binary::Div => Interval::div(l, r),
                    Binary::Min => Interval::min_of(l, r),
                    Binary::Max => Interval::max_of(l, r),
                }
            }
            Df::Spline(spline) => spline.range(env)?,
            Df::Lerp(args) => Interval::lerp(
                args[0].range(env)?,
                args[1].range(env)?,
                args[2].range(env)?,
            ),
            Df::Clamp { input, min, max } => Interval::clamp(input.range(env)?, min.0, max.0),
            Df::RangeChoice {
                in_range,
                out_of_range,
                ..
            } => Interval::encapsulating(&[in_range.range(env)?, out_of_range.range(env)?]),
            Df::IntervalSelect { functions, .. } => {
                Interval::encapsulating(&functions.iter().map(|f| f.range(env)).collect::<Result<
                    Vec<_>,
                    String,
                >>(
                )?)
            }
            Df::Cache(input)
            | Df::BlendDensity(input)
            | Df::Interpolated { input, .. }
            | Df::Slice { input, .. } => input.range(env)?,
            Df::FindTopSurface { upper, lower, .. } => {
                let lower = *lower as f32;
                Interval::of(lower, fmax(lower, upper.range(env)?.max))
            }
            Df::Blended(p) => blended_range(p[1].0 * 684.412 * p[4].0),
            Df::Prepared(i) => env.prepared(*i).0,
        })
    }
}

/// What range and axis queries need from their surroundings.
pub trait Env {
    fn function(&self, id: &str) -> Result<&Df, String>;
    /// The symmetric bound of a registry noise's range.
    fn noise_range(&self, id: &str) -> Result<f32, String>;
    /// A prepared cache's range and axes.
    fn prepared(&self, index: usize) -> (Interval, u8);
}

pub fn leaky_relu(negative_factor: f32, input: f32) -> f32 {
    if input > 0.0 {
        input
    } else {
        input * negative_factor
    }
}

pub fn squeeze(input: f32) -> f32 {
    let c = clamp(input, -1.0, 1.0);
    c / 2.0 - c * c * c / 24.0
}

fn unary_range(op: Unary, input: Interval) -> Interval {
    match op {
        Unary::Abs => Interval::abs(input),
        Unary::Square => Interval::square(input),
        Unary::Cube => Interval::map_monotonic(input, |x| x * x * x),
        Unary::Sqrt => pow_exact(input, 0.5),
        Unary::HalfNegative => Interval::map_monotonic(input, |x| leaky_relu(0.5, x)),
        Unary::QuarterNegative => Interval::map_monotonic(input, |x| leaky_relu(0.25, x)),
        Unary::Reciprocal => Interval::reciprocal(input),
        Unary::Negate => Interval::sub(Interval::exact(0.0), input),
        Unary::Squeeze => Interval::map_monotonic(input, squeeze),
        Unary::Log => {
            if input.max < 0.0 {
                NAI
            } else {
                Interval::map_monotonic(Interval::max_of(input, Interval::exact(0.0)), |x| {
                    (x as f64).ln() as f32
                })
            }
        }
        Unary::Sign => {
            if input.is_nai() {
                NAI
            } else if input.min == input.max {
                Interval::exact(if input.min == 0.0 || input.min.is_nan() {
                    input.min
                } else {
                    input.min.signum()
                })
            } else if input.contains(0.0) {
                if input.min == 0.0 {
                    Interval::of(0.0, 1.0)
                } else if input.max == 0.0 {
                    Interval::of(-1.0, 0.0)
                } else {
                    Interval::of(-1.0, 1.0)
                }
            } else {
                Interval::exact(if input.min > 0.0 { 1.0 } else { -1.0 })
            }
        }
    }
}

/// `Interval.pow` for an exact exponent.
fn pow_exact(base: Interval, exponent: f32) -> Interval {
    let at = |b: f32| {
        let v = (b as f64).powf(exponent as f64) as f32;
        if v.is_nan() {
            NAI
        } else {
            Interval::exact(v)
        }
    };
    if base.is_nai() {
        return NAI;
    }
    if base.min == base.max {
        return at(base.min);
    }
    let mut result = Interval::encapsulating(&[at(base.min), at(base.max)]);
    if base.contains(0.0) {
        if base.max > 0.0 {
            result = Interval::encapsulating(&[result, at(0.0)]);
        }
        if base.min < 0.0 {
            result = Interval::encapsulating(&[result, at(-0.0)]);
        }
    }
    result
}

/// `BlendedNoise.range()`: the limit octave set's range.
fn blended_range(smear_y: f64) -> Interval {
    let octaves = 16;
    let mut factor = 1.0f64;
    let mut value_factor = (0.99998474_f32 as f64) / ((1u64 << octaves) as f64 - 1.0);
    let mut range = Interval::exact(0.0);
    for _ in 0..octaves {
        let layer = Interval::mul(
            Interval::symmetric(((smear_y * factor).abs() + 2.0) as f32),
            Interval::exact(value_factor as f32),
        );
        range = Interval::add(range, layer);
        factor /= 2.0;
        value_factor *= 2.0;
    }
    range
}

impl Spline {
    pub fn parse(json: &Json) -> Result<Spline, String> {
        match json {
            Json::Number(n) => Ok(Spline::Constant(F32(*n as f32))),
            Json::Object(_) => {
                let coordinate = Df::parse(json.field("coordinate")?)?;
                let points = json.field("points")?.as_array()?;
                if points.is_empty() {
                    return Err("spline without points".into());
                }
                let mut locations = Vec::with_capacity(points.len());
                let mut values = Vec::with_capacity(points.len());
                let mut derivatives = Vec::with_capacity(points.len());
                for p in points {
                    let location = p.field("location")?.as_f64()? as f32;
                    if locations.last().is_some_and(|l: &F32| location <= l.0) {
                        return Err("spline locations must ascend".into());
                    }
                    locations.push(F32(location));
                    values.push(Spline::parse(p.field("value")?)?);
                    derivatives.push(F32(p.field("derivative")?.as_f64()? as f32));
                }
                Ok(Spline::Multipoint {
                    coordinate,
                    locations,
                    values,
                    derivatives,
                })
            }
            other => Err(format!("not a spline: {other:?}")),
        }
    }

    pub fn map_coordinates(
        &self,
        f: &mut dyn FnMut(&Df) -> Result<Df, String>,
    ) -> Result<Spline, String> {
        Ok(match self {
            Spline::Constant(v) => Spline::Constant(*v),
            Spline::Multipoint {
                coordinate,
                locations,
                values,
                derivatives,
            } => {
                let coordinate = f(coordinate)?;
                let values = values
                    .iter()
                    .map(|v| v.map_coordinates(f))
                    .collect::<Result<Vec<_>, String>>()?;
                Spline::Multipoint {
                    coordinate,
                    locations: locations.clone(),
                    values,
                    derivatives: derivatives.clone(),
                }
            }
        })
    }

    pub fn for_each_coordinate(
        &self,
        f: &mut dyn FnMut(&Df) -> Result<(), String>,
    ) -> Result<(), String> {
        if let Spline::Multipoint {
            coordinate, values, ..
        } = self
        {
            f(coordinate)?;
            for v in values {
                v.for_each_coordinate(f)?;
            }
        }
        Ok(())
    }

    fn range(&self, env: &dyn Env) -> Result<Interval, String> {
        let (coordinate, locations, values, derivatives) = match self {
            Spline::Constant(v) => return Ok(Interval::exact(v.0)),
            Spline::Multipoint {
                coordinate,
                locations,
                values,
                derivatives,
            } => (coordinate, locations, values, derivatives),
        };
        let last = locations.len() - 1;
        let (mut min, mut max) = (f32::INFINITY, f32::NEG_INFINITY);
        let input = coordinate.range(env)?;
        if input.is_nai() {
            return Ok(input);
        }
        let extend = |input: f32, value: f32, i: usize| {
            let d = derivatives[i].0;
            if d == 0.0 {
                value
            } else {
                value + d * (input - locations[i].0)
            }
        };
        if input.min < locations[0].0 {
            let first = values[0].range(env)?;
            let (e1, e2) = (
                extend(input.min, first.min, 0),
                extend(input.min, first.max, 0),
            );
            min = fmin(min, fmin(e1, e2));
            max = fmax(max, fmax(e1, e2));
        }
        if input.max > locations[last].0 {
            let last_range = values[last].range(env)?;
            let (e1, e2) = (
                extend(input.max, last_range.min, last),
                extend(input.max, last_range.max, last),
            );
            min = fmin(min, fmin(e1, e2));
            max = fmax(max, fmax(e1, e2));
        }
        let ranges = values
            .iter()
            .map(|v| v.range(env))
            .collect::<Result<Vec<_>, String>>()?;
        for r in &ranges {
            min = fmin(min, r.min);
            max = fmax(max, r.max);
        }
        for i in 0..last {
            let x_diff = locations[i + 1].0 - locations[i].0;
            let (r1, r2) = (ranges[i], ranges[i + 1]);
            let (d1, d2) = (derivatives[i].0, derivatives[i + 1].0);
            if d1 != 0.0 || d2 != 0.0 {
                let p1 = d1 * x_diff;
                let p2 = d2 * x_diff;
                let min_lerp1 = fmin(r1.min, r2.min);
                let max_lerp1 = fmax(r1.max, r2.max);
                let min_a = p1 - r2.max + r1.min;
                let max_a = p1 - r2.min + r1.max;
                let min_b = -p2 + r2.min - r1.max;
                let max_b = -p2 + r2.max - r1.min;
                let min_lerp2 = fmin(min_a, min_b);
                let max_lerp2 = fmax(max_a, max_b);
                min = fmin(min, min_lerp1 + 0.25 * min_lerp2);
                max = fmax(max, max_lerp1 + 0.25 * max_lerp2);
            }
        }
        Ok(Interval::of(min, max))
    }
}
