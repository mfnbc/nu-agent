use anyhow::Result;
use std::fs;

use nu_plugin_rag::state::{IndexBucket, RagPlugin};

fn main() -> Result<()> {
    // Build plugin and populate with 3 records
    let plugin = RagPlugin::new();
    let mut lock = plugin.indexes.lock().unwrap();
    let mut bucket = IndexBucket::default();
    bucket.dimension = Some(4);
    bucket.docs.push(nu_plugin_rag::state::DocRecord {
        id: "doc1".to_string(),
        embedding: vec![1.0f32, 0.0, 0.0, 0.0],
        value: nu_protocol::Value::string("alpha beta", nu_protocol::Span::unknown()),
    });
    bucket.docs.push(nu_plugin_rag::state::DocRecord {
        id: "doc2".to_string(),
        embedding: vec![0.0f32, 1.0, 0.0, 0.0],
        value: nu_protocol::Value::string("beta yellow", nu_protocol::Span::unknown()),
    });
    bucket.docs.push(nu_plugin_rag::state::DocRecord {
        id: "doc3".to_string(),
        embedding: vec![0.0f32, 0.0, 1.0, 0.0],
        value: nu_protocol::Value::string("rust code", nu_protocol::Span::unknown()),
    });

    lock.insert("integrity_test".to_string(), bucket.clone());
    drop(lock);

    // Save to temp path using the same compact shape as the plugin's index-save
    let path = "/tmp/integrity_test.msgpack";

    #[derive(serde::Serialize)]
    struct SavedDoc<'a> {
        id: &'a str,
        vector: &'a [f32],
        value: &'a nu_protocol::Value,
    }

    #[derive(serde::Serialize)]
    struct SavedBucket<'a> {
        dimension: Option<usize>,
        docs: Vec<SavedDoc<'a>>,
    }

    let docs: Vec<SavedDoc> = bucket
        .docs
        .iter()
        .map(|d| SavedDoc {
            id: &d.id,
            vector: &d.embedding,
            value: &d.value,
        })
        .collect();

    let sb = SavedBucket {
        dimension: bucket.dimension,
        docs,
    };

    let buf = rmp_serde::to_vec_named(&sb)?;
    fs::write(path, &buf)?;

    // Remove from plugin and then read file and reconstruct
    let mut lock = plugin.indexes.lock().unwrap();
    lock.remove("integrity_test");
    drop(lock);

    let buf = fs::read(path)?;

    #[derive(serde::Deserialize)]
    struct LoadedDoc {
        id: String,
        vector: Vec<f32>,
        value: nu_protocol::Value,
    }

    #[derive(serde::Deserialize)]
    struct LoadedBucket {
        dimension: Option<usize>,
        docs: Vec<LoadedDoc>,
    }

    let loaded: LoadedBucket = rmp_serde::from_slice(&buf)?;

    // Compare
    assert_eq!(bucket.dimension, loaded.dimension);
    assert_eq!(bucket.docs.len(), loaded.docs.len());
    for (a, b) in bucket.docs.iter().zip(loaded.docs.iter()) {
        assert_eq!(a.id, b.id);
        assert_eq!(a.embedding, b.vector);
    }

    println!("Round-trip integrity test PASSED");
    Ok(())
}
