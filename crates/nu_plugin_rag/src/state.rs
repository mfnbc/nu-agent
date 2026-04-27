use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use nu_plugin::{Plugin, PluginCommand};
use nu_protocol::Value;

use crate::commands::embed::Embed;

#[derive(Debug, Clone)]
pub struct DocRecord {
    pub id: String,
    pub embedding: Vec<f32>,
    #[allow(dead_code)]
    pub value: Value,
}

#[derive(Clone, Default)]
pub struct RagPlugin {
    #[allow(dead_code)]
    pub indexes: Arc<Mutex<HashMap<String, IndexBucket>>>,
}

#[derive(Debug, Clone, Default)]
pub struct IndexBucket {
    pub dimension: Option<usize>,
    pub docs: Vec<DocRecord>,
}

impl RagPlugin {
    pub fn new() -> Self {
        Self {
            indexes: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

impl Plugin for RagPlugin {
    fn version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    fn commands(&self) -> Vec<Box<dyn PluginCommand<Plugin = Self>>> {
        // Register embed and index commands
        vec![
            Box::new(Embed {}),
            Box::new(crate::commands::index::IndexCreate {}),
            Box::new(crate::commands::index::IndexAdd {}),
            Box::new(crate::commands::index::IndexSearch {}),
            Box::new(crate::commands::index::IndexStats {}),
            Box::new(crate::commands::index::IndexSave {}),
            Box::new(crate::commands::index::IndexLoad {}),
            Box::new(crate::commands::index::IndexList {}),
            Box::new(crate::commands::index::IndexRemove {}),
        ]
    }
}
