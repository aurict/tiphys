//! No usable desktop: every op is `unsupported` (only `ping` answers).

use super::Backend;

pub struct NoneBackend;

impl Backend for NoneBackend {
    fn name(&self) -> &'static str {
        "none"
    }
    fn capabilities(&self) -> Vec<&'static str> {
        Vec::new()
    }
}
