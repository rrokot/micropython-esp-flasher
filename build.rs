#[cfg(windows)]
fn main() {
    println!("cargo:rerun-if-changed=assets/mpflash.ico");
    winresource::WindowsResource::new()
        .set_icon("assets/mpflash.ico")
        .set("ProductName", "micropython-esp-flasher")
        .set("FileDescription", "MicroPython flasher for ESP32 boards")
        .set("OriginalFilename", "micropython-esp-flasher.exe")
        .compile()
        .expect("Cannot embed the Windows icon and version information");
}

#[cfg(not(windows))]
fn main() {}
