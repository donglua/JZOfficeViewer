use super::package::TestResult;
use roxmltree::Document;

pub fn annotate(source: &str, chapter: &str, path: &str) -> TestResult<String> {
    let (title, condition, expected) = match (chapter, path) {
        ("base", "ppt/slides/slide2.xml") => (
            "基础元素 · 文字、图形、图片与表格",
            "中英混排\n矩形、椭圆、线条\n嵌入 PNG 图片\n两列不同宽度的表格",
            "形状填色与描边可见\n青色图片完整显示\n表格文字没有裁切",
        ),
        ("base", "ppt/slides/slide1.xml") => (
            "深色背景 · 白色文字",
            "前一页是浅色背景\n本页改为深色背景\n英文文字指定白色",
            "示例区为深蓝色\n英文文字保持白色\n不沿用前页的浅色底",
        ),
        ("compat", "ppt/slides/slide2.xml") => (
            "组合变换 · 缩放、旋转与段落排版",
            "上方：嵌套组合与旋转\n中间：缩小适应、缩进\n下方：局部坐标缩放",
            "绿块拉宽，橙条转竖\n中间段落的续行缩进\n底部字号不随坐标放大",
        ),
        ("charts", "ppt/slides/slide2.xml") => (
            "柱状图 · 分类缓存",
            "外部数据不可用\n文件保存 Q1–Q4 分类\n包含 Alpha、Beta 两组",
            "每组并列 2 根柱体\n横轴按 Q1 到 Q4 排序\n图例色块与柱体一致",
        ),
        ("charts", "ppt/slides/slide1.xml") => (
            "折线图 · 日期缓存",
            "数值日期保存在文件内\n格式为 yyyy-mm-dd\n单组 Daily 数据",
            "横轴从 2024-01-01\n到 2024-01-04\n折线保留 4 个数据点\n不读取外部文件",
        ),
        ("colors", "ppt/slides/slide2.xml") => (
            "文字填色 · 渐变与纯色对照",
            "上：金色渐变输入\n中：等效亮金色纯色\n下：白色文字参照",
            "上、中两行颜色一致\n与下方白字明显区分\n渐变按中点纯色显示\n暂不呈现字内渐变",
        ),
        ("colors", "ppt/slides/slide1.xml") => (
            "文字填色 · 亮金与浅金对照",
            "同样文字、字号和背景\n依次使用亮金、浅金\n和白色三种纯色",
            "亮金色应明显偏黄\n浅金色较接近白色\n对照可见填色差别",
        ),
        ("typography", "ppt/slides/slide2.xml") => (
            "窄文本框 · 数字与空格",
            "5 个窄框，两位数字\n数字之间保留空格\nImpact 字体，1.8 倍行距",
            "每组数字同一行且居中\n字形随系统字体变化\n数字不能被裁切",
        ),
        ("typography", "ppt/slides/slide1.xml") => (
            "章节标题 · 字号与行距",
            "上方为 PART 01\n下方为较大的中文标题\n字体与段落行距不同",
            "两段文字完整可见\n两段之间不互相遮挡\n标题底部不会被裁切",
        ),
        ("backgrounds", "ppt/slides/slide1.xml") => (
            "背景继承 · 透明图片",
            "本页沿用版式渐变\n未直接指定背景\n中央 PNG 仅有白色横杠",
            "橙色渐变覆盖页面\n白杠周围透出背景\n不出现黑色图片底块",
        ),
        ("backgrounds", "ppt/slides/slide2.xml") => (
            "背景覆盖 · 渐变之后的纯色",
            "前一页使用橙色渐变\n本页背景改为深色\n青绿色矩形覆盖示例区",
            "示例区为均匀青绿色\n外围保持深色背景\n不残留前页橙色渐变",
        ),
        ("backgrounds", "ppt/slides/slide3.xml") => (
            "背景填充 · 旋转与翻转",
            "青绿色底上放两块图形\n两块均使用背景填充\n左：旋转；右：组内翻转",
            "橙色沿页面方向渐变\n不随图形一起转向\n两块矩形边缘完整",
        ),
        _ => return Err("showcase page has no explanation".into()),
    };
    let document = Document::parse(source)?;
    let id = document
        .descendants()
        .filter(|node| node.has_tag_name("cNvPr"))
        .map(|node| {
            node.attribute("id")
                .ok_or("shape ID missing")?
                .parse::<u32>()
                .map_err(Into::into)
        })
        .collect::<TestResult<Vec<_>>>()?
        .into_iter()
        .max()
        .unwrap_or(0)
        + 1;
    let title = paragraph(title, 3000, true, "FFFFFF");
    let notes = format!(
        "{}{}{}{}",
        paragraph("展示条件", 1900, true, "24745C"),
        paragraph(condition, 1800, false, "102238"),
        paragraph("预期效果", 1900, true, "24745C"),
        paragraph(expected, 1800, false, "102238")
    );
    let panels = format!(
        "{}{}{}",
        panel(id, [24, 16, 912, 58], ("102238", &title)),
        panel(id + 1, [704, 88, 232, 405], ("F4F7FA", &notes)),
        format_args!(
            r#"<p:sp><p:nvSpPr><p:cNvPr id="{}" name="Example boundary"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>{}<a:prstGeom prst="rect"/><a:noFill/><a:ln w="12700"><a:solidFill><a:srgbClr val="45CFC0"/></a:solidFill></a:ln></p:spPr></p:sp>"#,
            id + 2,
            transform([24, 88, 664, 374])
        )
    );
    let position = source.rfind("</p:spTree>").ok_or("slide tree missing")?;
    let mut output = source.to_owned();
    output.insert_str(position, &panels);
    Ok(output)
}

fn paragraph(text: &str, size: u32, bold: bool, color: &str) -> String {
    let bold = u8::from(bold);
    format!(
        r#"<a:p><a:pPr><a:lnSpc><a:spcPct val="120000"/></a:lnSpc><a:spcAft><a:spcPts val="1000"/></a:spcAft></a:pPr><a:r><a:rPr sz="{size}" b="{bold}"><a:solidFill><a:srgbClr val="{color}"/></a:solidFill></a:rPr><a:t>{text}</a:t></a:r></a:p>"#
    )
}

fn panel(id: u32, rect: [u32; 4], content: (&str, &str)) -> String {
    let (fill, paragraphs) = content;
    format!(
        r#"<p:sp><p:nvSpPr><p:cNvPr id="{id}" name="Showcase explanation"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr>{}<a:prstGeom prst="rect"/><a:solidFill><a:srgbClr val="{fill}"/></a:solidFill></p:spPr><p:txBody><a:bodyPr lIns="152400" rIns="152400" tIns="127000" bIns="127000"/><a:lstStyle/>{paragraphs}</p:txBody></p:sp>"#,
        transform(rect)
    )
}

fn transform(rect: [u32; 4]) -> String {
    let [x, y, width, height] = rect.map(|value| value * 12700);
    format!(r#"<a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{width}" cy="{height}"/></a:xfrm>"#)
}
