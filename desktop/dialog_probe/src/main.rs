use rfd::FileDialog;

fn main() {
    println!("dialog_probe:start");

    let files = FileDialog::new()
        .add_filter("audio", &["mp3", "wav", "m4a", "flac", "ogg", "aac", "wma"])
        .pick_files();

    match files {
        Some(paths) => {
            println!("dialog_probe:selected_count={}", paths.len());
            for path in paths {
                println!("dialog_probe:path={}", path.display());
            }
        }
        None => {
            println!("dialog_probe:cancelled");
        }
    }
}
