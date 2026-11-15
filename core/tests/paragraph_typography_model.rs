use jz_office_core::model::{is_zero_u32, Element, Paragraph, Run, WrapMode};

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

#[test]
fn default_element_omits_floating_fields_and_custom_serializes_in_json(
) -> Result<(), Box<dyn std::error::Error>> {
    let default_el = Element::default();
    let json_default = serde_json::to_value(&default_el)?;
    for key in [
        "wrapMode",
        "horizontalAlign",
        "behindDoc",
        "distTop",
        "distBottom",
        "distLeft",
        "distRight",
    ] {
        assert!(
            json_default.get(key).is_none(),
            "default element should omit {key}, got {:?}",
            json_default.get(key)
        );
    }

    let custom_el = Element {
        wrap_mode: WrapMode::TopAndBottom,
        horizontal_align: 2,
        behind_doc: true,
        dist_top: 4.5,
        dist_bottom: 6.0,
        dist_left: 9.0,
        dist_right: 12.0,
        ..Default::default()
    };
    let json_custom = serde_json::to_value(&custom_el)?;
    assert_eq!(json_custom["wrapMode"], "TOP_AND_BOTTOM");
    assert_eq!(json_custom["horizontalAlign"], 2);
    assert_eq!(json_custom["behindDoc"], true);
    assert_eq!(json_custom["distTop"], 4.5);
    assert_eq!(json_custom["distBottom"], 6.0);
    assert_eq!(json_custom["distLeft"], 9.0);
    assert_eq!(json_custom["distRight"], 12.0);
    Ok(())
}
