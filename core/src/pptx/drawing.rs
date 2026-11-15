use crate::model::{Document, Element, GradientFill, Page};

#[cfg(test)]
#[path = "drawing_tests.rs"]
mod tests;

pub(super) fn prepare(element: &mut Element, page: &Page, doc: &mut Document) -> bool {
    element.transform = element_transform(element);
    if element
        .transform
        .iter()
        .any(|value| !value.is_finite() || value.abs() > 100_000.0)
    {
        return false;
    }
    element.image_bounds = element.image_crop.map(|crop| {
        let width = element.width / (1.0 - crop.left - crop.right);
        let height = element.height / (1.0 - crop.top - crop.bottom);
        [
            -crop.left * width,
            -crop.top * height,
            (1.0 - crop.left) * width,
            (1.0 - crop.top) * height,
        ]
    });
    if let Some(fill) = &mut element.fill_gradient {
        let size = if fill.in_slide_space {
            let Some(inverse) = inverse(element.transform) else {
                element.fill_gradient = None;
                doc.warn("Slide background fill has an invalid shape transform");
                return true;
            };
            fill.transform = Some(inverse);
            [page.width, page.height]
        } else {
            [element.width, element.height]
        };
        fill.points = gradient_points(fill, size);
    }
    true
}

/// Computes local rotation/flip transform (without translating by `element.x`/`element.y`)
/// and linear gradient endpoints for DOCX shapes rendered within external flow coordinates.
pub(crate) fn prepare_local(element: &mut Element) {
    if element.rotation != 0.0 || element.flip_h || element.flip_v {
        let (x, y) = (element.x, element.y);
        element.x = 0.0;
        element.y = 0.0;
        element.transform = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
        let local = element_transform(element);
        element.x = x;
        element.y = y;
        if local.iter().all(|v| v.is_finite() && v.abs() <= 100_000.0) {
            element.transform = local;
        }
    }
    if let Some(fill) = &mut element.fill_gradient {
        fill.points = gradient_points(fill, [element.width, element.height]);
    }
}

fn element_transform(element: &Element) -> [f32; 6] {
    let [a, b, c, d, tx, ty] = element.transform;
    let translated = [
        a,
        b,
        c,
        d,
        tx + (a * element.x + c * element.y),
        ty + (b * element.x + d * element.y),
    ];
    let (sin, cos) = element.rotation.to_radians().sin_cos();
    // Match Android/Skia's rotation snapping so right angles remain axis-aligned.
    let sin = if sin.abs() <= 1.0 / 65536.0 { 0.0 } else { sin };
    let cos = if cos.abs() <= 1.0 / 65536.0 { 0.0 } else { cos };
    let (cx, cy) = (element.width / 2.0, element.height / 2.0);
    let rotated = concat(
        translated,
        [
            cos,
            sin,
            -sin,
            cos,
            sin * cy + (1.0 - cos) * cx,
            -sin * cx + (1.0 - cos) * cy,
        ],
    );
    concat(
        rotated,
        [
            if element.flip_h { -1.0 } else { 1.0 },
            0.0,
            0.0,
            if element.flip_v { -1.0 } else { 1.0 },
            if element.flip_h { element.width } else { 0.0 },
            if element.flip_v { element.height } else { 0.0 },
        ],
    )
}

fn concat(left: [f32; 6], right: [f32; 6]) -> [f32; 6] {
    let [a, b, c, d, tx, ty] = left.map(f64::from);
    let [e, f, g, h, x, y] = right.map(f64::from);
    // Skia accumulates affine products in double precision, then stores float coordinates.
    [
        (a * e + c * f) as f32,
        (b * e + d * f) as f32,
        (a * g + c * h) as f32,
        (b * g + d * h) as f32,
        (a * x + c * y) as f32 + tx as f32,
        (b * x + d * y) as f32 + ty as f32,
    ]
}

fn inverse(matrix: [f32; 6]) -> Option<[f32; 6]> {
    let [a, b, c, d, tx, ty] = matrix;
    let result = if b == 0.0 && c == 0.0 {
        let (sx, sy) = (1.0 / a, 1.0 / d);
        [sx, 0.0, 0.0, sy, -tx * sx, -ty * sy]
    } else {
        let [a, b, c, d, tx, ty] = matrix.map(f64::from);
        let determinant = a * d - b * c;
        // Preserve Skia's rejection of nearly singular affine background transforms.
        if (determinant as f32).abs() <= (1.0_f32 / 4096.0).powi(3) {
            return None;
        }
        let reciprocal = 1.0 / determinant;
        [d, -b, -c, a, c * ty - d * tx, b * tx - a * ty].map(|value| (value * reciprocal) as f32)
    };
    result
        .iter()
        .all(|value| value.is_finite())
        .then_some(result)
}

fn gradient_points(fill: &GradientFill, [width, height]: [f32; 2]) -> [f32; 4] {
    let radians = f64::from(fill.angle).to_radians();
    let (mut dx, mut dy) = (radians.cos() as f32, radians.sin() as f32);
    if fill.scaled {
        dx *= width;
        dy *= height;
    }
    let mut length = f64::from(dx).hypot(f64::from(dy)) as f32;
    if length < 0.0001 {
        dx = 1.0;
        dy = 0.0;
        length = 1.0;
    }
    dx /= length;
    dy /= length;
    let span = (width * dx).abs() + (height * dy).abs();
    let (cx, cy) = (width / 2.0, height / 2.0);
    [
        cx - dx * span / 2.0,
        cy - dy * span / 2.0,
        cx + dx * span / 2.0,
        cy + dy * span / 2.0,
    ]
}
