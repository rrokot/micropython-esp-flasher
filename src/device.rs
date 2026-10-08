use crate::{image::Image, repl::Running};
use anyhow::{Context, Result, ensure};
use espflash::{
    connection::{Connection, Port, ResetAfterOperation, ResetBeforeOperation},
    flasher::Flasher,
    target::{Chip, ProgressCallbacks, efuse},
};
use serde::Serialize;
use serialport::{SerialPortInfo, SerialPortType, UsbPortInfo};
use std::{fs, path::Path, time::Duration};

pub const ESPRESSIF: u16 = 0x303a;

#[derive(Debug)]
pub struct NoChip(pub String);
impl std::fmt::Display for NoChip {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for NoChip {}

#[derive(Clone, Debug, Serialize)]
pub struct PortInfo {
    pub name: String,
    pub vid: u16,
    pub pid: u16,
    pub serial: Option<String>,
    pub known: bool,
    pub firmware_usb: bool,
}

impl PortInfo {
    pub fn native(&self) -> bool {
        self.vid == ESPRESSIF
    }
    fn usb(&self) -> UsbPortInfo {
        UsbPortInfo {
            vid: self.vid,
            pid: self.pid,
            serial_number: self.serial.clone(),
            manufacturer: None,
            product: None,
        }
    }
}

fn convert_port(info: SerialPortInfo) -> Option<PortInfo> {
    let SerialPortType::UsbPort(usb) = info.port_type else {
        return None;
    };
    let firmware_usb = usb.vid == ESPRESSIF && usb.pid == 0x4001;
    Some(PortInfo {
        name: info.port_name,
        vid: usb.vid,
        pid: usb.pid,
        serial: usb.serial_number,
        known: matches!(usb.vid, ESPRESSIF | 0x0403 | 0x067b | 0x10c4 | 0x1a86) && !firmware_usb,
        firmware_usb,
    })
}

pub fn ports() -> Result<Vec<PortInfo>> {
    let mut ports: Vec<_> = serialport::available_ports()?
        .into_iter()
        .filter_map(convert_port)
        .collect();
    ports.sort_by_key(|port| {
        (
            !port.native(),
            port.name
                .trim_start_matches("COM")
                .parse::<u32>()
                .unwrap_or(0),
            port.name.clone(),
        )
    });
    Ok(ports)
}

#[derive(Clone, Debug, Serialize)]
pub struct Hardware {
    pub chip: Chip,
    pub board: String,
    pub flash_size: u32,
    pub psram_mb: u32,
    pub psram: bool,
    pub single_core: bool,
    pub package: Option<String>,
    pub mac: Option<String>,
}

impl Hardware {
    pub fn names(&self) -> Vec<String> {
        let mut names = vec![format!("FLASH_{}M", self.flash_size / 1024 / 1024)];
        if let Some(package) = &self.package {
            names.push(package.clone());
        }
        if self.single_core {
            names.push("UNICORE".into());
        }
        if self.psram {
            names.push("SPIRAM".into());
        }
        if self.psram_mb >= 8 {
            names.push("SPIRAM_OCT".into());
        }
        names
    }
}

pub struct Connected {
    pub flasher: Flasher,
    reset: bool,
}

impl Connected {
    pub fn open(port: &PortInfo, baud: Option<u32>) -> Result<Self> {
        let serial: Port = serialport::new(&port.name, 115_200)
            .timeout(Duration::from_secs(3))
            .dtr_on_open(false)
            .open_native()
            .with_context(|| format!("Cannot open {}", port.name))?;
        let after = if port.native() {
            ResetAfterOperation::WatchdogReset
        } else {
            ResetAfterOperation::HardReset
        };
        let connection = Connection::new(
            serial,
            port.usb(),
            after,
            ResetBeforeOperation::DefaultReset,
            115_200,
        );
        match Flasher::try_connect(connection, true, true, false, None, baud) {
            Ok(flasher) => Ok(Self {
                flasher,
                reset: true,
            }),
            Err(error) => {
                let (error, mut connection) = *error;
                let _ = connection.reset();
                Err(NoChip(format!(
                    "No supported ESP32 chip answered on {}: {error}",
                    port.name
                ))
                .into())
            }
        }
    }

    pub fn hardware(&mut self, running: Option<&Running>) -> Result<Hardware> {
        let info = self
            .flasher
            .device_info()
            .map_err(|error| anyhow::anyhow!("Cannot identify board: {error}"))?;
        let chip = info.chip;
        let mut psram_mb = 0;
        let mut psram = false;
        let mut package = None;
        if chip == Chip::Esp32s3 {
            // espflash's generic feature text does not expose S3 RAM capacity.
            let cap = chip
                .read_efuse_le::<u32>(self.flasher.connection(), efuse::esp32s3::PSRAM_CAP)?
                | chip
                    .read_efuse_le::<u32>(self.flasher.connection(), efuse::esp32s3::PSRAM_CAP_3)?
                    << 2;
            psram_mb = match cap {
                1 => 8,
                2 => 2,
                3 => 16,
                4 => 4,
                _ => 0,
            };
            psram = cap != 0;
        } else {
            for feature in &info.features {
                if feature.starts_with("Embedded PSRAM") {
                    psram = true;
                    psram_mb = feature
                        .split_whitespace()
                        .find_map(|part| part.strip_suffix("MB").and_then(|v| v.parse().ok()))
                        .unwrap_or(0);
                }
            }
        }
        if chip == Chip::Esp32 {
            let package_id = chip
                .read_efuse_le::<u32>(self.flasher.connection(), efuse::esp32::CHIP_PACKAGE)?
                | chip.read_efuse_le::<u32>(
                    self.flasher.connection(),
                    efuse::esp32::CHIP_PACKAGE_4BIT,
                )? << 3;
            package = match package_id {
                2 => Some("D2WD".into()),
                6 => Some("PICO_V3_02".into()),
                _ => None,
            };
        }
        if let Some(running) = running {
            psram_mb = psram_mb.max((running.psram / 1024 / 1024) as u32);
            psram |= running.psram > 0;
        }
        let suffix = chip.to_string().replace('-', "").to_uppercase();
        let suffix = suffix
            .strip_prefix("ESP32")
            .context("ESP8266 is not supported")?;
        let board = if suffix.is_empty() {
            "ESP32_GENERIC".into()
        } else {
            format!("ESP32_GENERIC_{suffix}")
        };
        let hardware = Hardware {
            chip,
            board,
            flash_size: info.flash_size.size(),
            psram_mb,
            psram,
            single_core: info.features.iter().any(|f| f == "Single Core"),
            package,
            mac: info.mac_address,
        };
        log::info!("Hardware: {}", serde_json::to_string(&hardware)?);
        Ok(hardware)
    }

    pub fn backup(&mut self, hardware: &Hardware, path: &Path) -> Result<()> {
        ensure!(!path.exists(), "Backup already exists: {}", path.display());
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            fs::create_dir_all(parent)?;
        }
        self.flasher
            .read_flash(0, hardware.flash_size, 0x1000, 64, path.to_owned())
            .map_err(|error| anyhow::anyhow!("Cannot back up flash: {error}"))?;
        ensure!(
            fs::metadata(path)?.len() == u64::from(hardware.flash_size),
            "Incomplete flash backup"
        );
        Ok(())
    }

    pub fn write(
        &mut self,
        hardware: &Hardware,
        path: &Path,
        erase: bool,
        progress: &mut dyn ProgressCallbacks,
    ) -> Result<()> {
        let image = Image::read(path)?;
        ensure!(
            image.chip_id == hardware.chip.id(),
            "Firmware is for another chip (image {}, board {})",
            image.chip_id,
            hardware.chip.id()
        );
        ensure!(
            image
                .offset
                .checked_add(image.length)
                .is_some_and(|end| end <= hardware.flash_size),
            "Firmware does not fit the board's flash"
        );
        ensure!(
            image.filesystem < hardware.flash_size,
            "The firmware leaves no space for board files"
        );
        let bytes = fs::read(path)?;
        if erase {
            self.flasher
                .erase_flash()
                .map_err(|error| anyhow::anyhow!("Cannot erase flash: {error}"))?;
        }
        self.flasher
            .write_bin_to_flash(image.offset, &bytes, progress)
            .map_err(|error| anyhow::anyhow!("Cannot write firmware: {error}"))?;
        // The library resets after a verified write. Do not reset the disappearing USB port twice.
        self.reset = false;
        Ok(())
    }
}

impl Drop for Connected {
    fn drop(&mut self) {
        if self.reset {
            let chip = self.flasher.chip();
            if let Err(error) = self.flasher.connection().reset_after(true, chip) {
                log::warn!("Cannot reset the board: {error}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_native_bridges_unknown_adapters_and_firmware_usb() {
        for (vid, pid, known, firmware_usb) in [
            (0x303a, 0x1001, true, false),
            (0x303a, 0x4001, false, true),
            (0x10c4, 0xea60, true, false),
            (0x1a86, 0x7523, true, false),
            (0x2341, 0x0043, false, false),
        ] {
            let info = SerialPortInfo {
                port_name: "COM5".into(),
                port_type: SerialPortType::UsbPort(UsbPortInfo {
                    vid,
                    pid,
                    serial_number: None,
                    manufacturer: None,
                    product: None,
                }),
            };
            let port = convert_port(info).unwrap();
            assert_eq!((port.known, port.firmware_usb), (known, firmware_usb));
        }
        assert!(
            convert_port(SerialPortInfo {
                port_name: "COM1".into(),
                port_type: SerialPortType::Unknown
            })
            .is_none()
        );
    }

    #[test]
    fn hardware_variants_include_packages_unicore_and_memory() {
        let h = Hardware {
            chip: Chip::Esp32,
            board: "ESP32_GENERIC".into(),
            flash_size: 2 * 1024 * 1024,
            psram_mb: 8,
            psram: true,
            single_core: true,
            package: Some("D2WD".into()),
            mac: None,
        };
        assert_eq!(
            h.names(),
            ["FLASH_2M", "D2WD", "UNICORE", "SPIRAM", "SPIRAM_OCT"]
        );
    }
}
