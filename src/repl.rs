use anyhow::{Context, Result, bail, ensure};
use serde::Serialize;
use serialport::SerialPort;
use std::{
    io::{Read, Write},
    thread,
    time::{Duration, Instant},
};

const WAIT: Duration = Duration::from_secs(5);
const MAX_REPLY: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, Default, Serialize)]
pub struct Running {
    pub version: String,
    pub machine: String,
    pub build: String,
    pub psram: u64,
    pub filesystem: Option<u32>,
}

const PROBE: &str = r#"import os, sys
u = os.uname()
print('version=' + u.version.split()[0][1:])
print('machine=' + u.machine)
print('build=' + getattr(sys.implementation, '_build', ''))
try:
    import esp32
    big = max(r[0] for r in esp32.idf_heap_info(esp32.HEAP_DATA))
    print('psram=%d' % (big if big >= 1 << 20 else 0))
except Exception:
    pass
try:
    import esp32
    parts = esp32.Partition.find(esp32.Partition.TYPE_DATA, label='vfs')
    if parts:
        print('fs=%d' % parts[0].info()[2])
except Exception:
    pass
"#;

pub trait Transport {
    fn send(&mut self, bytes: &[u8]) -> Result<()>;
    fn byte(&mut self, timeout: Duration) -> Result<u8>;
    fn pending(&self) -> Result<bool>;
    fn drain(&mut self) -> Result<Vec<u8>> {
        let mut bytes = Vec::new();
        while self.pending()? {
            ensure!(bytes.len() < MAX_REPLY, "Too much serial output");
            bytes.push(self.byte(Duration::from_secs(1))?);
        }
        Ok(bytes)
    }
}

struct SerialTransport(Box<dyn SerialPort>);

impl Transport for SerialTransport {
    fn send(&mut self, bytes: &[u8]) -> Result<()> {
        self.0.write_all(bytes)?;
        self.0.flush()?;
        Ok(())
    }
    fn byte(&mut self, timeout: Duration) -> Result<u8> {
        let start = Instant::now();
        let mut byte = [0];
        loop {
            match self.0.read(&mut byte) {
                Ok(1) => return Ok(byte[0]),
                Ok(_) => (),
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::TimedOut
                            | std::io::ErrorKind::WouldBlock
                            | std::io::ErrorKind::Interrupted
                    ) => {}
                Err(error) => return Err(error.into()),
            }
            ensure!(start.elapsed() < timeout, "The board stopped answering");
        }
    }
    fn pending(&self) -> Result<bool> {
        Ok(self.0.bytes_to_read()? > 0)
    }
}

pub struct Session {
    serial: SerialTransport,
    active: bool,
}

impl Session {
    pub fn open(port: &str, native_usb: bool) -> Result<Self> {
        let mut serial = serialport::new(port, 115_200)
            .timeout(Duration::from_millis(20))
            .dtr_on_open(native_usb)
            .open()
            .with_context(|| format!("Cannot open {port}"))?;
        serial.write_request_to_send(native_usb)?;
        Ok(Self {
            serial: SerialTransport(serial),
            active: false,
        })
    }

    pub fn connect(&mut self) -> Result<bool> {
        let start = Instant::now();
        let mut text = String::new();
        while start.elapsed() < Duration::from_secs(3) {
            self.serial.send(&[3, 3, 2])?;
            thread::sleep(Duration::from_millis(250));
            text.push_str(&String::from_utf8_lossy(&self.serial.drain()?));
            if text.trim_end().ends_with(">>>") {
                break;
            }
            ensure!(
                text.len() < MAX_REPLY,
                "Too much output while waiting for the REPL"
            );
        }
        log::debug!("REPL handshake: {text}");
        if !text.trim_end().ends_with(">>>") {
            ensure!(
                !text.contains("MicroPython"),
                "MicroPython did not reach the REPL; no firmware was written"
            );
            return Ok(false);
        }
        self.active = true;
        self.serial.send(&[1])?;
        let start = Instant::now();
        let mut quiet = Instant::now();
        let mut text = String::new();
        while start.elapsed() < Duration::from_secs(2) {
            let more = self.serial.drain()?;
            if !more.is_empty() {
                text.push_str(&String::from_utf8_lossy(&more));
                quiet = Instant::now();
            }
            if text.contains("raw REPL; CTRL-B to exit")
                && text.trim_end().ends_with('>')
                && quiet.elapsed() >= Duration::from_millis(200)
            {
                return Ok(true);
            }
            thread::sleep(Duration::from_millis(20));
        }
        bail!("MicroPython did not enter the raw REPL; no firmware was written")
    }

    pub fn execute(&mut self, code: &str) -> Result<String> {
        ensure!(self.active, "REPL is not connected");
        self.serial.drain()?;
        execute(&mut self.serial, code)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if self.active {
            let _ = self.serial.send(&[2, 4]);
            thread::sleep(Duration::from_millis(100));
        }
    }
}

fn read_until(serial: &mut dyn Transport, delimiter: u8) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    loop {
        let byte = serial.byte(WAIT)?;
        if byte == delimiter {
            return Ok(bytes);
        }
        ensure!(bytes.len() < MAX_REPLY, "REPL output exceeded the limit");
        bytes.push(byte);
    }
}

fn execute(serial: &mut dyn Transport, code: &str) -> Result<String> {
    serial.send(&[5, b'A', 1])?;
    ensure!(serial.byte(WAIT)? == b'R', "Invalid raw-paste response");
    let mode = serial.byte(WAIT)?;
    match mode {
        1 => {
            let window = usize::from(u16::from_le_bytes([serial.byte(WAIT)?, serial.byte(WAIT)?]));
            ensure!(window > 0, "Invalid raw-paste window");
            let mut room = window;
            let mut position = 0;
            let bytes = code.as_bytes();
            while position < bytes.len() {
                // Consume one flow-control byte at a time. An early Ctrl-D aborts the transfer.
                while room == 0 || serial.pending()? {
                    match serial.byte(WAIT)? {
                        1 => {
                            room = room
                                .checked_add(window)
                                .context("Invalid raw-paste flow control")?
                        }
                        4 => {
                            serial.send(&[4])?;
                            bail!("The board rejected the code");
                        }
                        other => bail!("Invalid raw-paste flow-control byte: {other}"),
                    }
                }
                let count = room.min(bytes.len() - position);
                serial.send(&bytes[position..position + count])?;
                position += count;
                room -= count;
            }
            serial.send(&[4])?;
            loop {
                match serial.byte(WAIT)? {
                    1 => (),
                    4 => break,
                    other => bail!("Invalid raw-paste acknowledgement: {other}"),
                }
            }
        }
        0 => {
            // Older MicroPython still accepts ordinary raw REPL input in small chunks.
            for chunk in code.as_bytes().chunks(128) {
                serial.send(chunk)?;
                thread::sleep(Duration::from_millis(10));
            }
            serial.send(&[4])?;
            ensure!(
                serial.byte(WAIT)? == b'O' && serial.byte(WAIT)? == b'K',
                "The board did not accept the code"
            );
        }
        other => bail!("Unknown raw-paste mode: {other}"),
    }
    let output = read_until(serial, 4)?;
    let error = read_until(serial, 4)?;
    ensure!(serial.byte(WAIT)? == b'>', "Missing raw REPL prompt");
    ensure!(
        error.is_empty(),
        "The board raised an error: {}",
        String::from_utf8_lossy(&error)
    );
    String::from_utf8(output).context("The board returned invalid UTF-8")
}

pub fn parse_probe(reply: &str) -> Result<Running> {
    let fields: std::collections::HashMap<_, _> = reply
        .lines()
        .filter_map(|line| line.split_once('='))
        .collect();
    let version = fields
        .get("version")
        .context("MicroPython returned no version")?
        .to_string();
    ensure!(
        crate::catalog::Version::parse(&version).is_some(),
        "Invalid MicroPython version: {version}"
    );
    Ok(Running {
        version,
        machine: fields.get("machine").unwrap_or(&"").to_string(),
        build: fields.get("build").unwrap_or(&"").to_string(),
        psram: fields
            .get("psram")
            .map(|text| text.parse())
            .transpose()?
            .unwrap_or(0),
        filesystem: fields.get("fs").map(|text| text.parse()).transpose()?,
    })
}

pub fn probe(port: &str, native_usb: bool) -> Result<Option<Running>> {
    let mut session = Session::open(port, native_usb)?;
    if !session.connect()? {
        return Ok(None);
    }
    let reply = session
        .execute(PROBE)
        .context("Cannot read MicroPython information; no firmware was written")?;
    log::info!("MicroPython on {port}: {reply}");
    Ok(Some(parse_probe(&reply)?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    struct Fake {
        replies: VecDeque<u8>,
        sent: Vec<Vec<u8>>,
        flow: bool,
    }
    impl Transport for Fake {
        fn send(&mut self, bytes: &[u8]) -> Result<()> {
            self.sent.push(bytes.to_vec());
            Ok(())
        }
        fn byte(&mut self, _: Duration) -> Result<u8> {
            self.replies.pop_front().context("timeout")
        }
        fn pending(&self) -> Result<bool> {
            Ok(self.flow && self.replies.front() == Some(&1))
        }
    }
    fn fake(bytes: &[u8]) -> Fake {
        Fake {
            replies: bytes.iter().copied().collect(),
            sent: Vec::new(),
            flow: true,
        }
    }

    #[test]
    fn raw_paste_obeys_window_and_consumes_late_grants() {
        let mut serial = fake(b"R\x01\x04\x00\x01\x01\x04answer\x04\x04>");
        assert_eq!(execute(&mut serial, "print(123)").unwrap(), "answer");
        assert_eq!(
            serial.sent.concat(),
            [b"\x05A\x01".as_slice(), b"print(123)", b"\x04"].concat()
        );
        assert!(serial.replies.is_empty());
    }

    #[test]
    fn raw_paste_transfer_resumes_when_window_is_empty() {
        let mut serial = fake(b"R\x01\x04\x00\x01\x01\x04\x04\x04>");
        serial.flow = false;
        execute(&mut serial, "0123456789").unwrap();
        assert_eq!(
            serial.sent[1..4],
            [b"0123".to_vec(), b"4567".to_vec(), b"89".to_vec()]
        );
    }

    #[test]
    fn old_raw_repl_is_supported_and_board_errors_are_not_empty_boards() {
        let mut serial = fake(b"R\x00OK\x04\x04>");
        assert_eq!(execute(&mut serial, "print(1)").unwrap(), "");
        let mut serial = fake(b"R\x01\x80\x00\x04\x04IndexError\x04>");
        assert!(
            execute(&mut serial, "x")
                .unwrap_err()
                .to_string()
                .contains("IndexError")
        );
    }

    #[test]
    fn malformed_and_truncated_raw_paste_fail() {
        for bytes in [
            b"R\x01\x00\x00".as_slice(),
            b"R\x01\x04\x00\x04unfinished",
            b"Z\x01",
        ] {
            assert!(execute(&mut fake(bytes), "12345").is_err());
        }
    }

    #[test]
    fn probe_handles_optional_memory_and_filesystem_without_losing_version() {
        let running = parse_probe("version=1.29.0\r\nmachine=ESP32 S3\r\nbuild=ESP32_GENERIC_S3-SPIRAM_OCT\r\npsram=8388608\r\nfs=2097152\r\n").unwrap();
        assert_eq!(running.psram, 8 * 1024 * 1024);
        assert_eq!(running.filesystem, Some(0x200000));
        let older = parse_probe("version=1.13\nbuild=\n").unwrap();
        assert_eq!(older.filesystem, None);
        assert_eq!(older.psram, 0);
        assert!(parse_probe("version=garbage\n").is_err());
        assert!(parse_probe("machine=ESP32\n").is_err());
    }
}
