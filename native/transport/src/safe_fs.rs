//! Mapping-relative I/O: keep each parent directory open and never follow child links.
use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
use cap_std::fs::{Dir, OpenOptions};
use std::{
    collections::HashMap,
    ffi::{c_char, CStr},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Component, Path},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
    time::{Duration, UNIX_EPOCH},
};
static FILES: OnceLock<Mutex<HashMap<u64, std::fs::File>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
static ERROR: Mutex<String> = Mutex::new(String::new());
fn files() -> &'static Mutex<HashMap<u64, std::fs::File>> {
    FILES.get_or_init(|| Mutex::new(HashMap::new()))
}
fn failure(e: io::Error) -> i64 {
    *ERROR.lock().unwrap() = e.to_string();
    if e.kind() == io::ErrorKind::NotFound {
        -2
    } else if e.kind() == io::ErrorKind::AlreadyExists {
        -3
    } else {
        -1
    }
}
unsafe fn text(ptr: *const c_char) -> io::Result<String> {
    if ptr.is_null() {
        return Err(io::Error::other("null path"));
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(str::to_owned)
        .map_err(io::Error::other)
}
fn parent(root: &str, rel: &str, create: bool) -> io::Result<(Dir, String)> {
    // A mapping root itself is chosen locally; all untrusted child components are no-follow.
    let mut dir = Dir::open_ambient_dir(root, cap_std::ambient_authority())?;
    let parts: Vec<_> = Path::new(rel).components().collect();
    if parts.is_empty() || parts.iter().any(|p| !matches!(p, Component::Normal(_))) {
        return Err(io::Error::other("invalid relative path"));
    }
    for component in &parts[..parts.len() - 1] {
        let name = component.as_os_str();
        if create {
            match dir.create_dir(name) {
                Ok(_) => {}
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e),
            }
        }
        dir = dir.open_dir_nofollow(name)?;
    }
    Ok((
        dir,
        parts
            .last()
            .unwrap()
            .as_os_str()
            .to_str()
            .ok_or_else(|| io::Error::other("invalid filename"))?
            .to_owned(),
    ))
}
fn open(root: &str, rel: &str, mode: i32) -> io::Result<std::fs::File> {
    let (dir, name) = parent(root, rel, mode == 1 || mode == 2)?;
    let mut options = OpenOptions::new();
    options.follow(FollowSymlinks::No);
    if mode == 0 || mode == 3 {
        options.read(true);
        #[cfg(windows)]
        if mode == 3 {
            use cap_std::fs::OpenOptionsExt;
            options.access_mode(0x00000100 | 0x00000080 | 0x00100000);
        }
    } else {
        options.write(true).create(true);
        if mode == 1 {
            options.truncate(true);
        } else {
            options.append(true);
        }
    }
    let file = dir.open_with(name, &options)?.into_std();
    if !file.metadata()?.is_file() {
        return Err(io::Error::other("not a regular file"));
    }
    Ok(file)
}
#[cfg(any(target_os = "linux", target_os = "android"))]
fn publish(src: &Dir, from: &str, dst: &Dir, to: &str) -> io::Result<()> {
    use std::{ffi::CString, os::fd::AsRawFd};
    let a = CString::new(from).map_err(io::Error::other)?;
    let b = CString::new(to).map_err(io::Error::other)?;
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            src.as_raw_fd(),
            a.as_ptr(),
            dst.as_raw_fd(),
            b.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if !matches!(
        error.raw_os_error(),
        Some(libc::ENOSYS) | Some(libc::EINVAL)
    ) {
        return Err(error);
    }
    // A hard link also atomically refuses an existing destination. Never fall back to rename.
    src.hard_link(from, dst, to)?;
    src.remove_file(from)
}
#[cfg(target_os = "macos")]
fn publish(src: &Dir, from: &str, dst: &Dir, to: &str) -> io::Result<()> {
    use std::{ffi::CString, os::fd::AsRawFd};
    let a = CString::new(from).map_err(io::Error::other)?;
    let b = CString::new(to).map_err(io::Error::other)?;
    if unsafe {
        libc::renameatx_np(
            src.as_raw_fd(),
            a.as_ptr(),
            dst.as_raw_fd(),
            b.as_ptr(),
            libc::RENAME_EXCL,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(windows)]
fn publish(src: &Dir, from: &str, dst: &Dir, to: &str) -> io::Result<()> {
    use cap_std::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Wdk::Storage::FileSystem::{
        FileRenameInformation, NtSetInformationFile, FILE_RENAME_INFORMATION,
    };
    use windows_sys::Win32::{Foundation::RtlNtStatusToDosError, System::IO::IO_STATUS_BLOCK};
    let mut options = OpenOptions::new();
    options
        .read(true)
        .access_mode(0x00010000 | 0x00000080 | 0x00100000)
        .follow(FollowSymlinks::No);
    let file = src.open_with(from, &options)?;
    let name: Vec<u16> = to.encode_utf16().collect();
    let size = (std::mem::offset_of!(FILE_RENAME_INFORMATION, FileName) + (name.len() + 1) * 2)
        .max(std::mem::size_of::<FILE_RENAME_INFORMATION>());
    let mut buffer = vec![0u64; size.div_ceil(8)];
    let info = buffer.as_mut_ptr().cast::<FILE_RENAME_INFORMATION>();
    unsafe {
        (*info).Anonymous.ReplaceIfExists = false;
        (*info).RootDirectory = dst.as_raw_handle();
        (*info).FileNameLength = (name.len() * 2) as u32;
        std::ptr::copy_nonoverlapping(name.as_ptr(), (*info).FileName.as_mut_ptr(), name.len());
        let mut status_block = IO_STATUS_BLOCK::default();
        let status = NtSetInformationFile(
            file.as_raw_handle(),
            &mut status_block,
            info.cast(),
            size as u32,
            FileRenameInformation,
        );
        if status >= 0 {
            Ok(())
        } else {
            Err(io::Error::from_raw_os_error(
                RtlNtStatusToDosError(status) as i32
            ))
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn mys_fs_open(root: *const c_char, rel: *const c_char, mode: i32) -> i64 {
    let result = (|| {
        let file = open(&text(root)?, &text(rel)?, mode)?;
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        files().lock().unwrap().insert(id, file);
        Ok(id as i64)
    })();
    result.unwrap_or_else(failure)
}
#[no_mangle]
pub unsafe extern "C" fn mys_fs_io(
    id: u64,
    bytes: *mut u8,
    len: usize,
    operation: i32,
    offset: u64,
) -> i64 {
    let result = (|| {
        let mut handles = files().lock().unwrap();
        let file = handles
            .get_mut(&id)
            .ok_or_else(|| io::Error::other("closed file"))?;
        match operation {
            0 => file
                .read(std::slice::from_raw_parts_mut(bytes, len))
                .map(|n| n as i64),
            1 => {
                file.write_all(std::slice::from_raw_parts(bytes, len))?;
                Ok(len as i64)
            }
            2 => file.seek(SeekFrom::Start(offset)).map(|n| n as i64),
            3 => file.metadata().map(|m| m.len() as i64),
            4 => file
                .metadata()?
                .modified()?
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .map_err(io::Error::other),
            _ => Err(io::Error::other("invalid file operation")),
        }
    })();
    result.unwrap_or_else(failure)
}
#[no_mangle]
pub extern "C" fn mys_fs_close(id: u64) {
    files().lock().unwrap().remove(&id);
}
#[no_mangle]
pub unsafe extern "C" fn mys_fs_path(
    root: *const c_char,
    rel: *const c_char,
    target: *const c_char,
    operation: i32,
    mtime: u64,
) -> i64 {
    let result = (|| {
        let root = text(root)?;
        let rel = text(rel)?;
        match operation {
            0 => open(&root, &rel, 0)?.metadata().map(|m| m.len() as i64),
            1 => {
                let (dir, name) = parent(&root, &rel, false)?;
                dir.remove_file(name)?;
                Ok(0)
            }
            2 | 3 => {
                let (dir, name) = parent(&root, &rel, operation == 2)?;
                if operation == 2 {
                    match dir.create_dir(&name) {
                        Ok(_) => {}
                        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                        Err(e) => return Err(e),
                    }
                    dir.open_dir_nofollow(&name)?;
                } else {
                    dir.remove_dir(&name)?;
                }
                Ok(0)
            }
            4 => {
                let target = text(target)?;
                let (src, name) = parent(&root, &rel, false)?;
                let (dst, to) = parent(&root, &target, true)?;
                // Refuse a swapped source link before publishing it. No link is ever followed.
                if !src.symlink_metadata(&name)?.is_file() {
                    return Err(io::Error::other("invalid part file"));
                }
                publish(&src, &name, &dst, &to)?;
                Ok(0)
            }
            5 => {
                let file = open(&root, &rel, 3)?;
                file.set_times(
                    std::fs::FileTimes::new()
                        .set_modified(UNIX_EPOCH + Duration::from_millis(mtime)),
                )?;
                Ok(0)
            }
            6 => {
                let (dir, name) = parent(&root, &rel, false)?;
                dir.open_dir_nofollow(name)?;
                Ok(0)
            }
            _ => Err(io::Error::other("invalid path operation")),
        }
    })();
    result.unwrap_or_else(failure)
}
#[no_mangle]
pub unsafe extern "C" fn mys_fs_error(out: *mut u8, size: usize) -> usize {
    let message = ERROR.lock().unwrap();
    let length = message.len().min(size);
    std::ptr::copy_nonoverlapping(message.as_ptr(), out, length);
    length
}

/// Length-prefixed UTF-8 child names, with F/D type; links are never traversed.
#[no_mangle]
pub unsafe extern "C" fn mys_fs_list(
    root: *const c_char,
    rel: *const c_char,
    out: *mut u8,
    size: usize,
) -> i64 {
    let result = (|| {
        let root = text(root)?;
        let rel = text(rel)?;
        let dir = if rel == "." {
            Dir::open_ambient_dir(root, cap_std::ambient_authority())?
        } else {
            let (parent, name) = parent(&root, &rel, false)?;
            parent.open_dir_nofollow(name)?
        };
        let mut bytes = Vec::new();
        for entry in dir.entries()? {
            let entry = entry?;
            let kind = entry.file_type()?;
            let tag = if kind.is_dir() {
                'D'
            } else if kind.is_file() {
                'F'
            } else {
                continue;
            };
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            bytes.extend_from_slice(format!("{tag}{}:", name.len()).as_bytes());
            bytes.extend_from_slice(name.as_bytes());
            if bytes.len() > 16 * 1024 * 1024 {
                return Err(io::Error::other("directory listing too large"));
            }
        }
        if bytes.len() <= size {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len());
        }
        Ok(bytes.len() as i64)
    })();
    result.unwrap_or_else(failure)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!(
            "mysend-safe-fs-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&p).unwrap();
        p
    }
    #[test]
    fn publish_never_replaces_a_competing_file() {
        let p = root();
        let dir = Dir::open_ambient_dir(&p, cap_std::ambient_authority()).unwrap();
        std::fs::write(p.join("part"), b"incoming").unwrap();
        std::fs::write(p.join("target"), b"local").unwrap();
        assert_eq!(
            publish(&dir, "part", &dir, "target").unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        assert_eq!(std::fs::read(p.join("target")).unwrap(), b"local");
        std::fs::remove_file(p.join("target")).unwrap();
        publish(&dir, "part", &dir, "target").unwrap();
        assert_eq!(std::fs::read(p.join("target")).unwrap(), b"incoming");
        drop(dir); // Windows directory handles intentionally prevent deletion while held.
        std::fs::remove_dir_all(p).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn symlinks_and_swapped_parents_cannot_redirect_open_handles() {
        let p = root();
        let outside = root();
        std::fs::create_dir(p.join("child")).unwrap();
        std::fs::write(outside.join("secret"), b"private").unwrap();
        std::os::unix::fs::symlink(&outside, p.join("escape")).unwrap();
        assert!(open(p.to_str().unwrap(), "escape/secret", 0).is_err());
        assert!(open(p.to_str().unwrap(), "escape/write", 1).is_err());
        let (dir, name) = parent(p.to_str().unwrap(), "child/new", false).unwrap();
        std::fs::rename(p.join("child"), p.join("old")).unwrap();
        std::os::unix::fs::symlink(&outside, p.join("child")).unwrap();
        dir.write(name, b"inside").unwrap();
        assert!(!outside.join("new").exists());
        std::fs::remove_dir_all(p).unwrap();
        std::fs::remove_dir_all(outside).unwrap();
    }
}
