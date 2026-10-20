//! A decoded JSON value: the form worldgen facts reach the core in (the NIF
//! shim converts decoded Elixir terms into it).

#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn field(&self, key: &str) -> Result<&Json, String> {
        self.get(key).ok_or_else(|| format!("missing field {key}"))
    }

    pub fn as_f64(&self) -> Result<f64, String> {
        match self {
            Json::Number(n) => Ok(*n),
            other => Err(format!("expected a number, got {other:?}")),
        }
    }

    pub fn as_i32(&self) -> Result<i32, String> {
        let n = self.as_f64()?;
        if n.fract() == 0.0 && n >= i32::MIN as f64 && n <= i32::MAX as f64 {
            Ok(n as i32)
        } else {
            Err(format!("expected an integer, got {n}"))
        }
    }

    pub fn as_str(&self) -> Result<&str, String> {
        match self {
            Json::String(s) => Ok(s),
            other => Err(format!("expected a string, got {other:?}")),
        }
    }

    pub fn as_bool(&self) -> Result<bool, String> {
        match self {
            Json::Bool(b) => Ok(*b),
            other => Err(format!("expected a boolean, got {other:?}")),
        }
    }

    pub fn as_array(&self) -> Result<&[Json], String> {
        match self {
            Json::Array(items) => Ok(items),
            other => Err(format!("expected an array, got {other:?}")),
        }
    }

    pub fn entries(&self) -> Result<&[(String, Json)], String> {
        match self {
            Json::Object(fields) => Ok(fields),
            other => Err(format!("expected an object, got {other:?}")),
        }
    }
}
