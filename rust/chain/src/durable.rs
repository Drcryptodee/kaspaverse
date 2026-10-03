//! The chain crate's one durable write: temp file in the same directory,
//! fsync, rename, fsync the directory.
//!
//! **One copy per crate, and this is the chain's.** The bridge keeps its own
//! `atomic_write` (the vault blob, the change cursor, the lockout), with a
//! test-only fault seam between the fsync and the rename that this crate
//! cannot see; the chain crate cannot reach it either, because the bridge
//! depends on the chain and not the other way round. Before PRE3-LOG the
//! chain had three hand-rolled copies of this discipline (`kvlog`'s wipe,
//! the history fill's durable JSON, and a compaction that skipped both
//! fsyncs) beside two cursors written with a bare `std::fs::write`. They all
//! go through here now.
//!
//! **Why every step.** The temp file lives in the target's directory so the
//! rename stays within one file system (atomic on POSIX). The data is
//! fsynced before the rename, or a crash can publish a name that points at
//! blocks never written: the phone's `/data` is f2fs, which has none of
//! ext4's `auto_da_alloc` heuristics for exactly this replace-by-rename
//! pattern. The directory is fsynced after it, or the rename itself can be
//! lost; that step is best-effort, because some platforms refuse a directory
//! fsync and the data is already durable by then.

use std::fs;
use std::io::{self, Write};
use std::path::Path;

/// Replace `path` with `bytes` so that a crash at any instant leaves either
/// the old file or the new one, never a torn mix. Creates the parent
/// directory on the way in.
pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent dir"))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{}.tmp", name.to_string_lossy()));
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    if let Ok(dir) = fs::File::open(dir) {
        let _ = dir.sync_all();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaces_whole_creates_the_directory_and_leaves_no_temp() {
        let dir = std::env::temp_dir().join(format!("kv-durable-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let path = dir.join("nested").join("scan.cursor");

        atomic_write(&path, b"a longer first version").unwrap();
        atomic_write(&path, b"second").unwrap();
        assert_eq!(
            fs::read(&path).unwrap(),
            b"second",
            "replaced whole, not overlaid"
        );
        let names: Vec<String> = fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            names,
            ["scan.cursor"],
            "the temp file is renamed away, never left behind"
        );

        let _ = fs::remove_dir_all(&dir);
    }
}
