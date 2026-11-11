use jz_office_core::model::{is_zero_u32, Paragraph, Run};

#[test]
fn helper_is_zero_u32_identifies_zero() {
    assert!(is_zero_u32(&0));
    assert!(!is_zero_u32(&1));
    assert!(!is_zero_u32(&0xFFFF_FF00));
}

#[test]
fn default_paragraph_and_run_omit_background_and_border_fields_in_json(
) -> Result<(), Box<dyn std::error::Error>> {
    let paragraph = Paragraph::default();
    let json = serde_json::to_value(&paragraph)?;

    assert!(
        json.get("background").is_none(),
        "default paragraph should omit background, got {:?}",
        json.get("background")
    );
    assert!(
        json.get("borderTop").is_none(),
        "default paragraph should omit borderTop, got {:?}",
        json.get("borderTop")
    );
    assert!(
        json.get("borderBottom").is_none(),
        "default paragraph should omit borderBottom, got {:?}",
        json.get("borderBottom")
    );
    assert!(
        json.get("borderLeft").is_none(),
        "default paragraph should omit borderLeft, got {:?}",
        json.get("borderLeft")
    );
    assert!(
        json.get("borderRight").is_none(),
        "default paragraph should omit borderRight, got {:?}",
        json.get("borderRight")
    );
    assert!(
        json.get("borderWidth").is_none(),
        "default paragraph should omit borderWidth, got {:?}",
        json.get("borderWidth")
    );

    let run = Run::default();
    let json_run = serde_json::to_value(&run)?;

    assert!(
        json_run.get("background").is_none(),
        "default run should omit background, got {:?}",
        json_run.get("background")
    );
    Ok(())
}

#[test]
fn custom_paragraph_and_run_serialize_background_and_borders_in_json(
) -> Result<(), Box<dyn std::error::Error>> {
    let paragraph = Paragraph {
        background: 0xFFFF_0000,
        border_top: 0xFF00_FF00,
        border_bottom: 0xFF00_00FF,
        border_left: 0xFF11_2233,
        border_right: 0xFF44_5566,
        border_width: 2.5,
        ..Default::default()
    };

    let json = serde_json::to_value(&paragraph)?;

    assert_eq!(json["background"], 0xFFFF_0000u32);
    assert_eq!(json["borderTop"], 0xFF00_FF00u32);
    assert_eq!(json["borderBottom"], 0xFF00_00FFu32);
    assert_eq!(json["borderLeft"], 0xFF11_2233u32);
    assert_eq!(json["borderRight"], 0xFF44_5566u32);
    assert_eq!(json["borderWidth"], 2.5);

    let run = Run {
        background: 0xFF00_FFFF,
        ..Default::default()
    };

    let json_run = serde_json::to_value(&run)?;
    assert_eq!(json_run["background"], 0xFF00_FFFFu32);
    Ok(())
}
