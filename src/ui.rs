use anyhow::{Result, bail, ensure};
use crossterm::{
    cursor::{self, Hide, MoveToColumn, MoveUp, Show},
    event::{
        self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers,
        MouseButton, MouseEventKind,
    },
    execute,
    style::{Attribute, Color, Print, ResetColor, SetAttribute, SetForegroundColor},
    terminal::{self, Clear, ClearType},
};
use espflash::target::ProgressCallbacks;
use std::{
    io::{self, IsTerminal},
    time::{Duration, Instant},
};

pub struct Ui {
    pub interactive: bool,
}

pub struct Item {
    pub label: String,
    pub hint: String,
    pub key: char,
    pub dangerous: bool,
}

impl Item {
    pub fn new(key: char, label: impl Into<String>, hint: impl Into<String>) -> Self {
        Self {
            key,
            label: label.into(),
            hint: hint.into(),
            dangerous: false,
        }
    }
    pub fn danger(mut self) -> Self {
        self.dangerous = true;
        self
    }
}

struct Input;
impl Input {
    fn start() -> Result<Self> {
        terminal::enable_raw_mode()?;
        if let Err(error) = execute!(io::stdout(), EnableMouseCapture, Hide) {
            let _ = terminal::disable_raw_mode();
            return Err(error.into());
        }
        Ok(Self)
    }
}
impl Drop for Input {
    fn drop(&mut self) {
        let _ = execute!(io::stdout(), DisableMouseCapture, Show);
        let _ = terminal::disable_raw_mode();
    }
}

fn is_key(key: &event::KeyEvent) -> bool {
    key.kind == KeyEventKind::Press
        && !matches!(
            key.code,
            KeyCode::Modifier(_)
                | KeyCode::Null
                | KeyCode::CapsLock
                | KeyCode::NumLock
                | KeyCode::ScrollLock
        )
        && !(key.code == KeyCode::Tab && key.modifiers.contains(KeyModifiers::ALT))
        && !key.modifiers.contains(KeyModifiers::SUPER)
}

fn interrupted(event: &Event) -> bool {
    matches!(event, Event::Key(key) if key.kind == KeyEventKind::Press && key.modifiers.contains(KeyModifiers::CONTROL) && matches!(key.code, KeyCode::Char('c' | 'C' | 'с' | 'С')))
}

fn hotkey(c: char) -> char {
    match c.to_ascii_lowercase() {
        'а' | 'А' => 'f',
        'у' | 'У' => 'e',
        'м' | 'М' => 'v',
        'ы' | 'Ы' => 's',
        'с' | 'С' => 'c',
        other => other,
    }
}

impl Ui {
    pub fn new() -> Self {
        Self {
            interactive: io::stdout().is_terminal() && io::stdin().is_terminal(),
        }
    }
    pub fn title(&self) {
        self.line(
            &format!("micropython-esp-flasher {}", env!("CARGO_PKG_VERSION")),
            Color::Cyan,
        );
        self.rule();
    }
    fn rule(&self) {
        let width = terminal::size().map_or(68, |(cols, _)| usize::from(cols).saturating_sub(4));
        self.line(&"─".repeat(width.min(68)), Color::DarkGrey);
    }
    pub fn section(&self, title: &str) {
        println!();
        self.line(title, Color::Cyan);
        self.rule();
    }
    pub fn line(&self, text: &str, color: Color) {
        log::info!("{text}");
        if self.interactive {
            let _ = execute!(
                io::stdout(),
                SetForegroundColor(color),
                Print(format!("  {text}\n")),
                ResetColor
            );
        } else {
            println!("  {text}");
        }
    }
    pub fn step(&self, label: &str, value: impl AsRef<str>) {
        let color = match label {
            "ready" | "verified" => Color::Green,
            "skip" => Color::Grey,
            "connect" | "writing" | "verify" | "tool" => Color::Cyan,
            _ => Color::White,
        };
        self.field(label, value.as_ref(), color);
    }
    fn field(&self, label: &str, value: &str, color: Color) {
        log::info!("{label:<12} {value}");
        if self.interactive {
            let _ = execute!(
                io::stdout(),
                SetForegroundColor(Color::Grey),
                Print(format!("  {label:<12} ")),
                SetForegroundColor(color),
                Print(format!("{value}\n")),
                ResetColor
            );
        } else {
            println!("  {label:<12} {value}");
        }
    }
    pub fn result(&self, port: &str, outcome: &str) {
        let color = match outcome {
            "skipped" | "would skip" => Color::Grey,
            "would flash" => Color::Cyan,
            _ => Color::Green,
        };
        self.field("result", &format!("{port}   {outcome}"), color);
    }
    pub fn summary(&self, written: usize, skipped: usize, failed: usize, preview: bool) {
        self.section(if preview {
            "Plan summary"
        } else {
            "Run summary"
        });
        self.field(
            if preview { "Would write" } else { "Written" },
            &written.to_string(),
            if preview { Color::Cyan } else { Color::Green },
        );
        self.field(
            if preview { "Would skip" } else { "Skipped" },
            &skipped.to_string(),
            Color::Grey,
        );
        self.field(
            "Failed",
            &failed.to_string(),
            if failed > 0 { Color::Red } else { Color::Grey },
        );
    }
    pub fn warning(&self, text: &str) {
        self.line(text, Color::Yellow);
    }
    pub fn error(&self, text: &str) {
        self.line(text, Color::Red);
    }
    pub fn card(&self, title: &str, fields: &[(&str, &str, Color)]) {
        self.section(title);
        for (label, value, color) in fields {
            self.field(label, value, *color);
        }
        println!();
    }
    pub fn countdown(&self, action: &str) -> Result<bool> {
        ensure!(
            self.interactive,
            "Use a terminal, or specify --yes to run without a menu"
        );
        let _input = Input::start()?;
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(5) {
            let left = 5 - start.elapsed().as_secs();
            execute!(
                io::stdout(),
                MoveToColumn(0),
                Clear(ClearType::CurrentLine),
                SetForegroundColor(Color::Cyan),
                Print(format!(
                    "  ► {action} in {left} s   press a key or click for options"
                )),
                ResetColor
            )?;
            if event::poll(Duration::from_millis(50))? {
                let input = event::read()?;
                if interrupted(&input) {
                    bail!("Cancelled");
                }
                let pressed = match input {
                    Event::Key(key) => is_key(&key),
                    Event::Mouse(mouse) => mouse.kind == MouseEventKind::Down(MouseButton::Left),
                    _ => false,
                };
                if pressed {
                    self.clear_live();
                    log::info!("Countdown interrupted: {action}");
                    return Ok(true);
                }
            }
        }
        self.clear_live();
        log::info!("Countdown completed: {action}");
        Ok(false)
    }
    fn clear_live(&self) {
        let _ = execute!(io::stdout(), MoveToColumn(0), Clear(ClearType::CurrentLine));
    }

    pub fn choose(
        &self,
        title: &str,
        items: &[Item],
        default: usize,
        escape: Option<usize>,
    ) -> Result<Option<usize>> {
        ensure!(!items.is_empty(), "Nothing to choose from");
        ensure!(
            self.interactive,
            "This choice needs a terminal; specify a port, variant or erase action explicitly"
        );
        self.line(title, Color::Cyan);
        let label_width = items
            .iter()
            .map(|item| item.label.chars().count())
            .max()
            .unwrap_or(0);
        let _input = Input::start()?;
        let mut selected = default.min(items.len() - 1);
        let mut drawn = false;
        loop {
            if drawn {
                execute!(
                    io::stdout(),
                    MoveUp(items.len() as u16 + 1),
                    MoveToColumn(0)
                )?;
            }
            for (index, item) in items.iter().enumerate() {
                execute!(
                    io::stdout(),
                    Clear(ClearType::CurrentLine),
                    SetForegroundColor(if item.dangerous {
                        Color::Red
                    } else if index == selected {
                        Color::Cyan
                    } else {
                        Color::Grey
                    }),
                    SetAttribute(if index == selected {
                        Attribute::Bold
                    } else {
                        Attribute::NormalIntensity
                    }),
                    Print(format!(
                        "  {} [{}] {:label_width$}",
                        if index == selected { "►" } else { " " },
                        item.key,
                        item.label
                    )),
                    SetAttribute(Attribute::NormalIntensity),
                    SetForegroundColor(if item.dangerous {
                        Color::Yellow
                    } else {
                        Color::Grey
                    }),
                    Print(format!("  {}\r\n", item.hint)),
                    ResetColor
                )?;
            }
            execute!(
                io::stdout(),
                Clear(ClearType::CurrentLine),
                SetForegroundColor(Color::DarkGrey),
                Print("    ↑↓ or mouse   enter to choose   esc to cancel\r\n"),
                ResetColor
            )?;
            drawn = true;
            let (_, row) = cursor::position()?;
            let top = row.saturating_sub(items.len() as u16 + 1);
            let input = event::read()?;
            if interrupted(&input) {
                bail!("Cancelled");
            }
            let answer = match input {
                Event::Key(key) if is_key(&key) => match key.code {
                    KeyCode::Up => {
                        selected = selected.saturating_sub(1);
                        None
                    }
                    KeyCode::Down => {
                        selected = (selected + 1).min(items.len() - 1);
                        None
                    }
                    KeyCode::Enter => Some(Some(selected)),
                    KeyCode::Esc => Some(escape),
                    KeyCode::Char(c) => items
                        .iter()
                        .position(|item| item.key == hotkey(c))
                        .map(Some),
                    _ => None,
                },
                Event::Mouse(mouse) => {
                    if mouse.row >= top && usize::from(mouse.row - top) < items.len() {
                        selected = usize::from(mouse.row - top);
                    }
                    match mouse.kind {
                        MouseEventKind::Down(MouseButton::Left)
                            if mouse.row >= top && usize::from(mouse.row - top) < items.len() =>
                        {
                            Some(Some(selected))
                        }
                        MouseEventKind::ScrollUp => {
                            selected = selected.saturating_sub(1);
                            None
                        }
                        MouseEventKind::ScrollDown => {
                            selected = (selected + 1).min(items.len() - 1);
                            None
                        }
                        _ => None,
                    }
                }
                _ => None,
            };
            if let Some(answer) = answer {
                log::info!(
                    "Menu '{title}': {}",
                    answer.map_or("cancel", |index| items[index].label.as_str())
                );
                return Ok(answer);
            }
        }
    }

    pub fn pause(&self) -> Result<()> {
        if self.interactive {
            self.line("Press a key to close", Color::DarkGrey);
            let _input = Input::start()?;
            loop {
                if let Event::Key(key) = event::read()?
                    && is_key(&key)
                {
                    break;
                }
            }
        }
        Ok(())
    }
}

pub struct Progress<'a> {
    ui: &'a Ui,
    start: Instant,
    total: usize,
    percent: usize,
}
impl<'a> Progress<'a> {
    pub fn new(ui: &'a Ui) -> Self {
        Self {
            ui,
            start: Instant::now(),
            total: 0,
            percent: usize::MAX,
        }
    }
}
impl ProgressCallbacks for Progress<'_> {
    fn init(&mut self, addr: u32, total: usize) {
        self.total = total;
        self.start = Instant::now();
        self.ui
            .step("writing", format!("0x{addr:x}, {total} blocks"));
    }
    fn update(&mut self, current: usize) {
        let percent = current.saturating_mul(100) / self.total.max(1);
        if percent == self.percent {
            return;
        }
        self.percent = percent;
        if self.ui.interactive {
            let filled = percent.min(100) / 4;
            let _ = execute!(
                io::stdout(),
                MoveToColumn(0),
                Clear(ClearType::CurrentLine),
                SetForegroundColor(Color::Cyan),
                Print(format!(
                    "  ► writing   {}{}  {percent:3}%  {:.1}s",
                    "█".repeat(filled),
                    "░".repeat(25 - filled),
                    self.start.elapsed().as_secs_f32()
                )),
                ResetColor
            );
        } else if percent.is_multiple_of(10) {
            self.ui.step("writing", format!("{percent}%"));
        }
    }
    fn verifying(&mut self) {
        if self.ui.interactive {
            self.ui.clear_live();
        }
        self.ui.step("verify", "checking flash checksum");
    }
    fn finish(&mut self, skipped: bool) {
        if self.ui.interactive {
            self.ui.clear_live();
        }
        self.ui.step(
            "verified",
            if skipped {
                "already written".to_owned()
            } else {
                format!("completed in {:.1}s", self.start.elapsed().as_secs_f32())
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modifiers_and_layout_changes_do_not_interrupt_countdown() {
        assert!(!is_key(&event::KeyEvent::new(
            KeyCode::Modifier(event::ModifierKeyCode::LeftShift),
            KeyModifiers::SHIFT
        )));
        assert!(!is_key(&event::KeyEvent::new(
            KeyCode::Tab,
            KeyModifiers::ALT
        )));
        assert!(!is_key(&event::KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::SUPER
        )));
        assert!(is_key(&event::KeyEvent::new(
            KeyCode::Char('f'),
            KeyModifiers::NONE
        )));
        assert_eq!(hotkey('а'), 'f');
        assert_eq!(hotkey('У'), 'e');
        assert_eq!(hotkey('М'), 'v');
    }
}
