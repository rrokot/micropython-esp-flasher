use crate::{
    catalog::{Build, Version},
    repl::Running,
};
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Change {
    Install,
    Update,
    WrongBuild,
    UpToDate,
    Newer,
}

impl Change {
    pub fn needed(self) -> bool {
        matches!(self, Self::Install | Self::Update | Self::WrongBuild)
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Install => "install needed",
            Self::Update => "update available",
            Self::WrongBuild => "wrong build for this hardware",
            Self::UpToDate => "up to date",
            Self::Newer => "newer than the catalog",
        }
    }
}

pub fn running_variant<'a>(board: &str, running: &'a Running) -> Option<&'a str> {
    if running.build == board {
        Some("")
    } else {
        running
            .build
            .strip_prefix(&format!("{board}-"))
            .filter(|variant| !variant.is_empty())
    }
}

pub fn classify(board: &str, running: Option<&Running>, build: &Build) -> Change {
    let Some(running) = running else {
        return Change::Install;
    };
    let Some(current) = Version::parse(&running.version) else {
        return Change::Install;
    };
    if current < build.version || (current == build.version && running.version.contains("preview"))
    {
        Change::Update
    } else if current > build.version {
        Change::Newer
    } else if running_variant(board, running).is_some_and(|variant| variant != build.variant) {
        Change::WrongBuild
    } else {
        Change::UpToDate
    }
}

pub fn files_move(board: &str, running: &Running, variant: &str, filesystem: u32) -> bool {
    running.filesystem.map_or_else(
        || running_variant(board, running) != Some(variant),
        |current| current != filesystem,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build() -> Build {
        Build {
            name: "x".into(),
            variant: "SPIRAM_OCT".into(),
            version: Version(1, 29, 0),
            date: "20260824".into(),
        }
    }
    fn running(version: &str, build: &str) -> Running {
        Running {
            version: version.into(),
            build: build.into(),
            ..Default::default()
        }
    }

    #[test]
    fn install_update_preview_wrong_variant_and_no_automatic_downgrade() {
        let b = build();
        assert_eq!(classify("ESP32_GENERIC_S3", None, &b), Change::Install);
        for version in ["1.28.0", "1.29.0-preview.12.gabc"] {
            assert_eq!(
                classify(
                    "ESP32_GENERIC_S3",
                    Some(&running(version, "ESP32_GENERIC_S3")),
                    &b
                ),
                Change::Update
            );
        }
        assert_eq!(
            classify(
                "ESP32_GENERIC_S3",
                Some(&running("1.29.0", "ESP32_GENERIC_S3")),
                &b
            ),
            Change::WrongBuild
        );
        assert_eq!(
            classify(
                "ESP32_GENERIC_S3",
                Some(&running("1.29.0", "ESP32_GENERIC_S3-SPIRAM_OCT")),
                &b
            ),
            Change::UpToDate
        );
        assert_eq!(
            classify(
                "ESP32_GENERIC_S3",
                Some(&running("1.30.0", "ESP32_GENERIC_S3")),
                &b
            ),
            Change::Newer
        );
        assert!(!Change::Newer.needed());
        assert!(!Change::UpToDate.needed());
    }

    #[test]
    fn filesystem_location_has_priority_over_variant_with_safe_fallback() {
        let mut r = running("1.29.0", "ESP32_GENERIC_S3");
        r.filesystem = Some(0x200000);
        assert!(!files_move("ESP32_GENERIC_S3", &r, "SPIRAM_OCT", 0x200000));
        assert!(files_move("ESP32_GENERIC_S3", &r, "", 0x300000));
        r.filesystem = None;
        assert!(!files_move("ESP32_GENERIC_S3", &r, "", 0x200000));
        assert!(files_move("ESP32_GENERIC_S3", &r, "SPIRAM_OCT", 0x200000));
        r.build.clear();
        assert!(files_move("ESP32_GENERIC_S3", &r, "", 0x200000));
    }
}
