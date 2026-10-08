use anyhow::{Context, Result, bail, ensure};
use std::{fs::File, io::Read, path::Path};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Image {
    pub offset: u32,
    pub filesystem: u32,
    pub chip_id: u16,
    pub length: u32,
}

fn word(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
}

fn is_partition(bytes: &[u8], at: usize) -> bool {
    bytes.get(at..at + 32).is_some_and(|entry| {
        entry[..2] == [0xaa, 0x50]
            && entry[2] <= 1
            && word(entry, 4).is_multiple_of(0x1000)
            && word(entry, 8) > 0
    })
}

impl Image {
    pub fn read(path: &Path) -> Result<Self> {
        let file = File::open(path).with_context(|| format!("Cannot open {}", path.display()))?;
        let length = u32::try_from(file.metadata()?.len()).context("Firmware is too large")?;
        let mut bytes = Vec::new();
        file.take(0x9000).read_to_end(&mut bytes)?;
        Self::parse(&bytes, length)
    }

    pub fn parse(bytes: &[u8], length: u32) -> Result<Self> {
        ensure!(
            bytes.len() >= 24 && bytes[0] == 0xe9,
            "Not an ESP32 firmware image"
        );
        let offsets: Vec<_> = (0..0x8000)
            .step_by(0x1000)
            .filter(|offset| is_partition(bytes, 0x8000 - offset))
            .collect();
        ensure!(
            offsets.len() == 1,
            "Cannot locate a unique partition table in the firmware"
        );
        let offset = offsets[0] as u32;
        let mut at = 0x8000 - offsets[0];
        let mut end = 0;
        let mut filesystem = None;
        while is_partition(bytes, at) {
            let start = word(bytes, at + 4);
            let size = word(bytes, at + 8);
            let partition_end = start
                .checked_add(size)
                .context("Partition address overflow")?;
            end = end.max(partition_end);
            let label = bytes[at + 12..at + 28]
                .split(|byte| *byte == 0)
                .next()
                .unwrap();
            if bytes[at + 2] == 1 && label == b"vfs" {
                ensure!(filesystem.is_none(), "Multiple vfs partitions in firmware");
                filesystem = Some(start);
            }
            at += 32;
        }
        let filesystem = filesystem.unwrap_or(end);
        let written_end = offset
            .checked_add(length)
            .context("Firmware address overflow")?;
        if written_end > filesystem {
            bail!("Firmware overlaps the filesystem (0x{written_end:x} > 0x{filesystem:x})");
        }
        Ok(Self {
            offset,
            filesystem,
            chip_id: u16::from_le_bytes([bytes[12], bytes[13]]),
            length,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn firmware(offset: usize, vfs: bool) -> Vec<u8> {
        let mut bytes = vec![0xff; 0x9000];
        bytes[0] = 0xe9;
        bytes[12..14].copy_from_slice(&9_u16.to_le_bytes());
        let at = 0x8000 - offset;
        bytes[at..at + 32].fill(0);
        bytes[at..at + 2].copy_from_slice(&[0xaa, 0x50]);
        bytes[at + 2] = u8::from(vfs);
        bytes[at + 4..at + 8].copy_from_slice(&0x200000_u32.to_le_bytes());
        bytes[at + 8..at + 12].copy_from_slice(&0x100000_u32.to_le_bytes());
        if vfs {
            bytes[at + 12..at + 15].copy_from_slice(b"vfs");
        }
        bytes
    }

    #[test]
    fn locates_bootloader_and_filesystem() {
        for offset in [0, 0x1000, 0x2000] {
            let image = Image::parse(&firmware(offset, true), 0x180000).unwrap();
            assert_eq!(image.offset, offset as u32);
            assert_eq!(image.filesystem, 0x200000);
            assert_eq!(image.chip_id, 9);
        }
    }

    #[test]
    fn filesystem_after_last_partition_without_vfs() {
        assert_eq!(
            Image::parse(&firmware(0x1000, false), 0x180000)
                .unwrap()
                .filesystem,
            0x300000
        );
    }

    #[test]
    fn rejects_invalid_truncated_ambiguous_and_overlapping_images() {
        assert!(Image::parse(b"not firmware", 12).is_err());
        let mut bytes = firmware(0, true);
        assert!(Image::parse(&bytes[..0x800f], 0x800f).is_err());
        assert!(Image::parse(&bytes, 0x200001).is_err());
        let entry = bytes[0x8000..0x8020].to_vec();
        bytes[0x7000..0x7020].copy_from_slice(&entry);
        assert!(Image::parse(&bytes, 0x9000).is_err());
    }

    #[test]
    fn rejects_partition_address_overflow() {
        let mut bytes = firmware(0, false);
        bytes[0x8004..0x8008].copy_from_slice(&0xfffff000_u32.to_le_bytes());
        assert!(Image::parse(&bytes, 0x9000).is_err());
    }
}
