//! fff's file search in-process, for the file-index Benchmark chunk.
//!
//!   fff-harness <root> <query>...
//!
//! Prints, per query, `## <query> <total matched> <ms>` and then every matched
//! file's absolute path, so `scripts/file-index-recall.py --fff` can score recall.
//! The time is one in-process search after the scan; it is a latency number
//! only on a quiet machine and a release build.

use std::path::Path;
use std::time::{Duration, Instant};

use fff_search::file_picker::FilePicker;
use fff_search::{
    FFFMode, FilePickerOptions, FuzzySearchOptions, PaginationArgs, QueryParser, SharedFilePicker, SharedFrecency,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let root = args.next().ok_or("usage: fff-harness <root> <query>...")?;
    let queries: Vec<String> = args.collect();

    let picker = SharedFilePicker::default();
    let started = Instant::now();
    FilePicker::new_with_shared_state(
        picker.clone(),
        SharedFrecency::default(),
        FilePickerOptions { base_path: root.clone(), mode: FFFMode::Ai, watch: false, ..Default::default() },
    )?;
    if !picker.wait_for_scan(Duration::from_secs(600)) {
        return Err("fff scan did not finish in 600 s".into());
    }
    eprintln!("scan {:.0} ms", started.elapsed().as_secs_f64() * 1000.0);

    let guard = picker.read()?;
    let picker = guard.as_ref().ok_or("fff picker missing after scan")?;
    let parser = QueryParser::default();
    let base = Path::new(&root);
    for raw in &queries {
        let query = parser.parse(raw);
        let options = |limit| FuzzySearchOptions {
            max_threads: 0,
            current_file: None,
            pagination: PaginationArgs { offset: 0, limit },
            ..Default::default()
        };
        let started = Instant::now();
        let first = picker.fuzzy_search(&query, None, options(50));
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        let all = picker.fuzzy_search(&query, None, options(first.total_matched.max(1)));
        println!("## {raw} {} {ms:.2}", first.total_matched);
        for item in all.items {
            println!("{}", item.absolute_path(picker, base).display());
        }
    }
    Ok(())
}
