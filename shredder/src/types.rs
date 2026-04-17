use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct NuDocChunk {
    pub id: String,
    pub identity: Identity,
    pub hierarchy: Hierarchy,
    pub taxonomy: Taxonomy,
    pub data: Data,
    pub embedding_input: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Identity {
    pub source: String,
    pub path: String,
    pub checksum: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Hierarchy {
    pub title: String,
    pub heading_path: Vec<String>,
    pub order: usize,
    pub parent_id: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Taxonomy {
    pub chunk_type: ChunkType,
    pub commands: Vec<String>,
    pub tags: Vec<String>,
    pub complexity: Complexity,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "snake_case")]
pub enum ChunkType {
    Concept,
    CommandRef,
    Example,
    Troubleshooting,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "snake_case")]
pub enum Complexity {
    Beginner,
    Intermediate,
    Advanced,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Data {
    pub content: String,
    pub code_blocks: Vec<CodeBlock>,
    pub links: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct CodeBlock {
    pub code: String,
    pub language: String,
    pub description: Option<String>,
    pub is_idiomatic: bool,
}
