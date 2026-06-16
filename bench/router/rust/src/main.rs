use std::fs;
use std::time::Instant;

fn read_lines(path: &str) -> Vec<String> {
    fs::read_to_string(path)
        .expect(&format!("failed to read {}", path))
        .lines()
        .map(|s| s.to_string())
        .collect()
}

fn main() {
    let routes = read_lines("../routes.txt");
    let paths = read_lines("../paths.txt");

    let mut router = matchit::Router::new();
    for route in &routes {
        router.insert(route, ()).unwrap();
    }

    let iterations = 1000usize;
    let start = Instant::now();
    for _ in 0..iterations {
        for path in &paths {
            let _ = router.at(path).unwrap();
        }
    }
    let elapsed = start.elapsed();

    let total_lookups = iterations * paths.len();
    let ns = elapsed.as_nanos() as f64;
    let ns_per_lookup = ns / total_lookups as f64;
    let lookups_per_sec = total_lookups as f64 / elapsed.as_secs_f64();

    println!(
        "matchit: {} lookups in {:.3}s => {:.1} ns/lookup, {:.1} lookups/sec",
        total_lookups,
        elapsed.as_secs_f64(),
        ns_per_lookup,
        lookups_per_sec
    );
}
