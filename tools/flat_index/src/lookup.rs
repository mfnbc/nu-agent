use serde_json::Value;
use std::fs;
fn main() {
    let idx: Value = serde_json::from_slice(&fs::read("data/nu_idioms.index").unwrap()).unwrap();
    let ids = idx["ids"].as_array().unwrap();
    let paths = idx["paths"].as_array().unwrap();
    let weights = idx["weights"].as_array().unwrap();
    let res = [
        "4f0765b08b69226679df081184b2a69ae360daaee7e907e59aa0c374cf54fea7",
        "b651020011655a2f0aada9e4e4e2e72bc147b96442dc43d2892b12bbdb21e684",
        "a0be47df66ae8304f15768c417c3514e0ea5f6786904362525d7a3dddbd3bcbd",
        "0e6e6470a09bab19c933ea30c7ff0357df0de10aaba924b0b8104797db9d7758",
        "ca38e3d904d187e97772452fb7f60ec3bc96b507ff7a02cb18c881dda2e9facb",
    ];
    for r in res {
        for (i, id) in ids.iter().enumerate() {
            if id.as_str().unwrap() == r {
                println!(
                    "{} {} {}",
                    r,
                    paths[i].as_str().unwrap(),
                    weights[i].as_i64().unwrap()
                );
            }
        }
    }
}
