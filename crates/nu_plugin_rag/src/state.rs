use nu_plugin::{Plugin, PluginCommand};

use crate::commands::{embed::Embed, shred::Shred, similarity::Similarity};

#[derive(Clone, Default)]
pub struct RagPlugin;

impl RagPlugin {
    pub fn new() -> Self {
        Self {}
    }
}

impl Plugin for RagPlugin {
    fn version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    fn commands(&self) -> Vec<Box<dyn PluginCommand<Plugin = Self>>> {
        vec![
            Box::new(Shred {}),
            Box::new(Embed {}),
            Box::new(Similarity {}),
        ]
    }
}
