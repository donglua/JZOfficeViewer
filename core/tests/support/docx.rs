use super::package::{content_types, relationships, xml, Parts, PNG};

pub const HEADER_REFERENCE: &str = r#"<w:headerReference w:type="default" r:id="rHeader"/>"#;
pub const FOOTER_REFERENCE: &str = r#"<w:footerReference w:type="default" r:id="rFooter"/>"#;

pub fn parts() -> Parts {
    vec![
        xml(
            "[Content_Types].xml",
            &content_types(&[
                ("word/document.xml", "wordprocessingml.document.main"),
                ("word/styles.xml", "wordprocessingml.styles"),
                ("word/header1.xml", "wordprocessingml.header"),
                ("word/footer1.xml", "wordprocessingml.footer"),
            ]),
        ),
        xml(
            "_rels/.rels",
            &relationships(&[("rOffice", "officeDocument", "word/document.xml")]),
        ),
        xml("word/document.xml", DOCUMENT),
        xml("word/styles.xml", STYLES),
        xml("word/header1.xml", HEADER),
        xml("word/footer1.xml", FOOTER),
        xml(
            "word/_rels/document.xml.rels",
            &relationships(&[
                ("rStyles", "styles", "styles.xml"),
                ("rImage", "image", "media/../media/pixel.png"),
                ("rHeader", "header", "header1.xml"),
                ("rFooter", "footer", "footer1.xml"),
            ]),
        ),
        ("word/media/pixel.png", PNG.to_vec()),
    ]
}

pub const STYLES: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/><w:color w:val="202124"/></w:rPr></w:rPrDefault></w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
  <w:style w:type="paragraph" w:styleId="BaseTitle">
    <w:name w:val="Base Title"/><w:basedOn w:val="Normal"/>
    <w:pPr><w:spacing w:before="240" w:after="160"/></w:pPr>
    <w:rPr><w:b/><w:color w:val="336699"/><w:sz w:val="36"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="FixtureTitle">
    <w:name w:val="Fixture Title"/><w:basedOn w:val="BaseTitle"/>
    <w:pPr><w:jc w:val="center"/></w:pPr>
  </w:style>
</w:styles>"#;

pub const HEADER: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
  <w:r><w:rPr><w:b/><w:color w:val="52606D"/><w:sz w:val="18"/></w:rPr><w:t>JZ Office Viewer 示例文档</w:t></w:r>
</w:p>
</w:hdr>"#;

pub const FOOTER: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
  <w:r><w:rPr><w:color w:val="9AA0A6"/><w:sz w:val="16"/></w:rPr><w:t>页脚：DOCX 页眉页脚已支持</w:t></w:r>
</w:p>
</w:ftr>"#;

pub const DOCUMENT: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
 xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
 xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
<w:body>
  <w:p><w:pPr><w:pStyle w:val="FixtureTitle"/></w:pPr>
    <w:r><w:t>&#x4E2D;&#x6587; Office</w:t></w:r>
    <w:r><w:rPr><w:b w:val="0"/><w:i/><w:u w:val="single"/><w:color w:val="C03020"/><w:sz w:val="28"/></w:rPr>
      <w:t xml:space="preserve"> English regular</w:t></w:r>
  </w:p>
  <w:p><w:r><w:t>Plain paragraph with </w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>italic</w:t></w:r>
    <w:r><w:tab/><w:t>tab</w:t><w:br/><w:t>next line</w:t></w:r></w:p>
  <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">
    <wp:extent cx="914400" cy="457200"/>
    <wp:docPr id="1" name="Small teal PNG"/>
    <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
    <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
      <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="pixel.png"/><pic:cNvPicPr/></pic:nvPicPr>
        <pic:blipFill><a:blip r:embed="rImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="457200"/></a:xfrm>
          <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
      </pic:pic>
    </a:graphicData></a:graphic>
  </wp:inline></w:drawing></w:r></w:p>
  <w:tbl><w:tblPr><w:tblW w:w="7200" w:type="dxa"/>
    <w:tblBorders><w:top w:val="single" w:sz="4" w:color="999999"/>
      <w:left w:val="single" w:sz="4" w:color="999999"/><w:bottom w:val="single" w:sz="4" w:color="999999"/>
      <w:right w:val="single" w:sz="4" w:color="999999"/><w:insideH w:val="single" w:sz="4" w:color="999999"/>
      <w:insideV w:val="single" w:sz="4" w:color="999999"/></w:tblBorders></w:tblPr>
    <w:tblGrid><w:gridCol w:w="2880"/><w:gridCol w:w="4320"/></w:tblGrid>
    <w:tr><w:tc><w:tcPr><w:tcW w:w="2880" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Language</w:t></w:r></w:p></w:tc>
      <w:tc><w:tcPr><w:tcW w:w="4320" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Greeting</w:t></w:r></w:p></w:tc></w:tr>
    <w:tr><w:tc><w:tcPr><w:tcW w:w="2880" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>&#x4E2D;&#x6587;</w:t></w:r></w:p></w:tc>
      <w:tc><w:tcPr><w:tcW w:w="4320" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Hello &#x4F60;&#x597D;</w:t></w:r></w:p></w:tc></w:tr>
  </w:tbl>
  <w:sectPr><w:headerReference w:type="default" r:id="rHeader"/><w:footerReference w:type="default" r:id="rFooter"/>
    <w:pgSz w:w="12240" w:h="15840"/>
    <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
  </w:sectPr>
</w:body></w:document>"#;
