use jz_office_core::{clear_package_cache, read_part, read_part_limited, Error, MEDIA_PART_LIMIT};
use std::fs;
use std::io::{self, Cursor, Read};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

type TestResult<T = ()> = Result<T, Box<dyn std::error::Error>>;
const MIB: u64 = 1024 * 1024;

struct TempArchive {
    path: PathBuf,
}

impl TempArchive {
    fn new(entries: &[(&str, &[u8])]) -> TestResult<Self> {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("jz_test_archive_{}_{}.zip", std::process::id(), id));

        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        for &(name, data) in entries {
            writer.start_file(name, options)?;
            io::copy(&mut Cursor::new(data), &mut writer)?;
        }
        let bytes = writer.finish()?.into_inner();
        fs::write(&path, bytes)?;
        Ok(Self { path })
    }

    fn new_deflated_padded(name: &str, size: u64) -> TestResult<Self> {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "jz_test_archive_deflated_{}_{}.zip",
            std::process::id(),
            id
        ));

        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        writer.start_file(name, options)?;
        io::copy(&mut io::repeat(0x42).take(size), &mut writer)?;
        let bytes = writer.finish()?.into_inner();
        fs::write(&path, bytes)?;
        Ok(Self { path })
    }
}

impl Drop for TempArchive {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[test]
fn read_part_fetches_content_and_reuses_cache() -> TestResult {
    let archive = TempArchive::new(&[
        ("word/media/image1.png", b"PNG_DATA_1"),
        ("word/media/image2.png", b"PNG_DATA_2"),
    ])?;

    let img1 = read_part(&archive.path, "word/media/image1.png")?;
    assert_eq!(img1, b"PNG_DATA_1");

    // Second read should reuse cached Package and central directory index
    let img2 = read_part(&archive.path, "word/media/image2.png")?;
    assert_eq!(img2, b"PNG_DATA_2");

    assert!(matches!(
        read_part(&archive.path, "word/media/nonexistent.png"),
        Err(Error::MissingPart(_))
    ));
    Ok(())
}

#[test]
fn read_part_enforces_media_part_limit() -> TestResult {
    // 16 MiB + 1 byte entry
    let archive = TempArchive::new_deflated_padded("large.bin", MEDIA_PART_LIMIT + 1)?;

    let result = read_part(&archive.path, "large.bin");
    assert!(matches!(
        result,
        Err(Error::Limit("Package part is too large"))
    ));
    Ok(())
}

#[test]
fn read_part_succeeds_for_large_media_over_two_mib() -> TestResult {
    // 3 MiB entry (simulating high-res image like image8.png which exceeds OpenHarmony Node-API 2 MiB Buffer threshold)
    let archive = TempArchive::new_deflated_padded("image_3mb.png", 3 * 1024 * 1024)?;

    let result = read_part(&archive.path, "image_3mb.png")?;
    assert_eq!(result.len(), 3 * 1024 * 1024);
    Ok(())
}

#[test]
fn read_part_limited_allows_custom_limit() -> TestResult {
    let archive = TempArchive::new(&[("small.bin", b"0123456789")])?;

    assert!(matches!(
        read_part_limited(&archive.path, "small.bin", 5),
        Err(Error::Limit("Package part is too large"))
    ));

    let data = read_part_limited(&archive.path, "small.bin", 20)?;
    assert_eq!(data, b"0123456789");
    Ok(())
}

#[test]
fn read_part_accumulates_budget_and_enforces_256_mib_across_calls() -> TestResult {
    // Single 16 MiB part
    let archive = TempArchive::new_deflated_padded("chunk.bin", 16 * MIB)?;

    // Read 16 times (16 * 16 MiB = 256 MiB)
    for _ in 0..16 {
        let data = read_part(&archive.path, "chunk.bin")?;
        assert_eq!(data.len() as u64, 16 * MIB);
    }

    // 17th read must exceed 256 MiB budget in the same cached package
    let result = read_part(&archive.path, "chunk.bin");
    assert!(matches!(
        result,
        Err(Error::Limit("Package read budget exceeded"))
    ));
    Ok(())
}

#[test]
fn read_part_invalidates_cache_when_file_is_modified() -> TestResult {
    let archive = TempArchive::new(&[("data.txt", b"OLD_DATA")])?;

    let old_data = read_part(&archive.path, "data.txt")?;
    assert_eq!(old_data, b"OLD_DATA");

    // Overwrite archive with new data (sleep briefly to guarantee modified time tick if fs has coarse mtime)
    std::thread::sleep(std::time::Duration::from_millis(50));
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    writer.start_file("data.txt", options)?;
    io::copy(&mut Cursor::new(b"NEW_DATA_UPDATED"), &mut writer)?;
    let bytes = writer.finish()?.into_inner();
    fs::write(&archive.path, bytes)?;

    // Cache should detect length/mtime change and return NEW_DATA_UPDATED
    let new_data = read_part(&archive.path, "data.txt")?;
    assert_eq!(new_data, b"NEW_DATA_UPDATED");
    Ok(())
}

#[test]
fn clear_cache_evicts_all_entries() -> TestResult {
    let archive = TempArchive::new(&[("test.bin", b"DATA")])?;
    let data = read_part(&archive.path, "test.bin")?;
    assert_eq!(data, b"DATA");

    clear_package_cache();

    // After clearing cache, read should still succeed by reloading
    let reloaded = read_part(&archive.path, "test.bin")?;
    assert_eq!(reloaded, b"DATA");
    Ok(())
}
