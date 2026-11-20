//! Captured pixels → scaled RGB → JPEG/PNG, plus base64 for `screenshot` answers.

use crate::protocol::{Error, Res};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PixelFormat {
    /// 4 bytes B, G, R, X/A (X11 ZPixmap on little-endian, GDI, CoreGraphics).
    Bgrx,
    #[allow(dead_code)] // portal (PNG) only
    Rgba,
    Rgb,
}

impl PixelFormat {
    pub fn bytes(self) -> usize {
        match self {
            Self::Bgrx | Self::Rgba => 4,
            Self::Rgb => 3,
        }
    }
}

/// Raw captured pixels; `stride` bytes per row (≥ width × bytes per pixel).
#[derive(Debug, Clone)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub format: PixelFormat,
    pub data: Vec<u8>,
}

impl Frame {
    pub fn new(width: u32, height: u32, stride: usize, format: PixelFormat, data: Vec<u8>) -> Res<Self> {
        if width == 0 || height == 0 || stride < width as usize * format.bytes() || data.len() < stride * height as usize {
            return Err(Error::failed("captured image has an unexpected size"));
        }
        Ok(Self { width, height, stride, format, data })
    }

    fn rgb_at(&self, x: usize, y: usize) -> [u8; 3] {
        let i = y * self.stride + x * self.format.bytes();
        let p = &self.data[i..];
        match self.format {
            PixelFormat::Bgrx => [p[2], p[1], p[0]],
            PixelFormat::Rgba | PixelFormat::Rgb => [p[0], p[1], p[2]],
        }
    }

    /// Cheap content hash (stream mode skips frames that didn't change).
    pub fn fingerprint(&self) -> u64 {
        // FNV-1a over 8-byte words (~1 ms for 1080p); every byte counts, so a blinking cursor is a change.
        let mut h: u64 = 0xcbf29ce484222325;
        for chunk in self.data.as_chunks::<8>().0 {
            h ^= u64::from_le_bytes(*chunk);
            h = h.wrapping_mul(0x100000001b3);
        }
        h ^ ((self.width as u64) << 32 | self.height as u64)
    }
}

/// Packed RGB image ready for encoding.
#[derive(Debug, Clone, PartialEq)]
pub struct Rgb {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

/// Output size for a `maxWidth`: never upscaled, aspect kept, at least 1 px.
pub fn fit(width: u32, height: u32, max_width: Option<u32>) -> (u32, u32) {
    match max_width {
        Some(m) if width > m => (m, ((height as u64 * m as u64 + width as u64 / 2) / width as u64).max(1) as u32),
        _ => (width, height),
    }
}

/// Converts to RGB and scales down by averaging the source pixels under each output pixel.
pub fn to_rgb(f: &Frame, max_width: Option<u32>) -> Rgb {
    let (w, h) = fit(f.width, f.height, max_width);
    let (sw, sh) = (f.width as usize, f.height as usize);
    let mut out = Vec::with_capacity(w as usize * h as usize * 3);
    if (w, h) == (f.width, f.height) {
        for y in 0..sh {
            for x in 0..sw {
                out.extend_from_slice(&f.rgb_at(x, y));
            }
        }
        return Rgb { width: w, height: h, data: out };
    }
    let (w, h) = (w as usize, h as usize);
    // Column spans are the same for every row.
    let cols: Vec<(usize, usize)> = (0..w).map(|x| span(x, w, sw)).collect();
    let mut acc = vec![[0u32; 3]; w];
    for y in 0..h {
        let (y0, y1) = span(y, h, sh);
        acc.iter_mut().for_each(|a| *a = [0; 3]);
        for sy in y0..y1 {
            for (x, &(x0, x1)) in cols.iter().enumerate() {
                for sx in x0..x1 {
                    let p = f.rgb_at(sx, sy);
                    acc[x][0] += p[0] as u32;
                    acc[x][1] += p[1] as u32;
                    acc[x][2] += p[2] as u32;
                }
            }
        }
        for (x, &(x0, x1)) in cols.iter().enumerate() {
            let n = ((x1 - x0) * (y1 - y0)) as u32;
            out.extend(acc[x].iter().map(|&c| ((c + n / 2) / n) as u8));
        }
    }
    Rgb { width: w as u32, height: h as u32, data: out }
}

/// Source range [a, b) covered by output index `i` of `n` over `src` (never empty).
fn span(i: usize, n: usize, src: usize) -> (usize, usize) {
    let a = i * src / n;
    let b = ((i + 1) * src / n).max(a + 1).min(src);
    (a, b)
}

pub fn encode_jpeg(img: &Rgb, quality: u8) -> Res<Vec<u8>> {
    if img.width > u16::MAX as u32 || img.height > u16::MAX as u32 {
        return Err(Error::failed("image too large for JPEG"));
    }
    let mut out = Vec::with_capacity(img.data.len() / 8);
    let enc = jpeg_encoder::Encoder::new(&mut out, quality.clamp(1, 100));
    enc.encode(&img.data, img.width as u16, img.height as u16, jpeg_encoder::ColorType::Rgb)
        .map_err(|e| Error::failed(format!("JPEG encoding failed: {e}")))?;
    Ok(out)
}

pub fn encode_png(img: &Rgb) -> Res<Vec<u8>> {
    let mut out = Vec::with_capacity(img.data.len() / 4);
    let mut enc = png::Encoder::new(&mut out, img.width, img.height);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    enc.set_compression(png::Compression::Fast);
    let fail = |e: png::EncodingError| Error::failed(format!("PNG encoding failed: {e}"));
    let mut w = enc.write_header().map_err(fail)?;
    w.write_image_data(&img.data).map_err(fail)?;
    w.finish().map_err(fail)?;
    Ok(out)
}

/// Decodes a PNG (portal screenshots) into a frame.
#[cfg(all(target_os = "linux", feature = "portal"))]
pub fn decode_png(bytes: &[u8]) -> Res<Frame> {
    let fail = |e: png::DecodingError| Error::failed(format!("PNG decoding failed: {e}"));
    let mut dec = png::Decoder::new(std::io::Cursor::new(bytes));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info().map_err(fail)?;
    let size = reader.output_buffer_size().ok_or_else(|| Error::failed("PNG too large"))?;
    let mut buf = vec![0; size];
    let info = reader.next_frame(&mut buf).map_err(fail)?;
    let format = match info.color_type {
        png::ColorType::Rgb => PixelFormat::Rgb,
        png::ColorType::Rgba => PixelFormat::Rgba,
        other => return Err(Error::failed(format!("unexpected PNG color type {other:?}"))),
    };
    buf.truncate(info.buffer_size());
    Frame::new(info.width, info.height, info.line_size, format, buf)
}

/// Decodes binary PPM (`grim -t ppm`) into a frame.
#[cfg(target_os = "linux")]
pub fn decode_ppm(bytes: &[u8]) -> Res<Frame> {
    let bad = || Error::failed("unexpected PPM data");
    // Header: "P6" ws width ws height ws maxval single-ws, comments start with '#'.
    let mut fields = Vec::with_capacity(4);
    let mut i = 0;
    while fields.len() < 4 {
        while i < bytes.len() && (bytes[i].is_ascii_whitespace() || bytes[i] == b'#') {
            if bytes[i] == b'#' {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            } else {
                i += 1;
            }
        }
        let start = i;
        while i < bytes.len() && !bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if start == i {
            return Err(bad());
        }
        fields.push(std::str::from_utf8(&bytes[start..i]).map_err(|_| bad())?);
    }
    if fields[0] != "P6" || fields[3] != "255" {
        return Err(bad());
    }
    let w: u32 = fields[1].parse().map_err(|_| bad())?;
    let h: u32 = fields[2].parse().map_err(|_| bad())?;
    let data = bytes.get(i + 1..).ok_or_else(bad)?;
    Frame::new(w, h, w as usize * 3, PixelFormat::Rgb, data.to_vec())
}

/// MJPEG quantizer (2 best … 31 worst, like `wf-recorder -p qmin=N`) → JPEG quality.
/// The inverse of the agent's `qscale()`: q = 100 − (qscale − 2) / 0.29.
pub fn mjpeg_quality(qscale: u8) -> u8 {
    let q = 100.0 - (qscale.clamp(2, 31) as f64 - 2.0) / 0.29;
    (q.round() as i64).clamp(5, 95) as u8
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { B64[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { B64[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bgrx(w: u32, h: u32, f: impl Fn(u32, u32) -> [u8; 3]) -> Frame {
        let stride = w as usize * 4 + 8; // padded rows like real captures
        let mut data = vec![0u8; stride * h as usize];
        for y in 0..h {
            for x in 0..w {
                let [r, g, b] = f(x, y);
                let i = y as usize * stride + x as usize * 4;
                data[i..i + 4].copy_from_slice(&[b, g, r, 255]);
            }
        }
        Frame::new(w, h, stride, PixelFormat::Bgrx, data).unwrap()
    }

    #[test]
    fn fits() {
        assert_eq!(fit(1920, 1080, Some(1280)), (1280, 720));
        assert_eq!(fit(1920, 1080, None), (1920, 1080));
        assert_eq!(fit(800, 600, Some(1280)), (800, 600), "never upscaled");
        assert_eq!(fit(4000, 1, Some(64)), (64, 1));
    }

    #[test]
    fn converts_and_scales() {
        let f = bgrx(4, 2, |x, _| if x < 2 { [200, 0, 0] } else { [0, 0, 100] });
        let full = to_rgb(&f, None);
        assert_eq!((full.width, full.height), (4, 2));
        assert_eq!(&full.data[..3], &[200, 0, 0]);
        assert_eq!(&full.data[9..12], &[0, 0, 100]);
        let half = to_rgb(&f, Some(2));
        assert_eq!((half.width, half.height), (2, 1));
        assert_eq!(half.data, vec![200, 0, 0, 0, 0, 100]);
        // Averaging: a 2x2 block of 0 and 255 becomes mid grey.
        let checker = bgrx(2, 2, |x, y| if (x + y) % 2 == 0 { [255; 3] } else { [0; 3] });
        assert_eq!(to_rgb(&checker, Some(1)).data, vec![128, 128, 128]);
        // Odd ratios cover every source pixel without panicking.
        let odd = bgrx(1366, 769, |x, y| [(x % 256) as u8, (y % 256) as u8, 7]);
        let s = to_rgb(&odd, Some(1000));
        assert_eq!(s.data.len(), (s.width * s.height * 3) as usize);
    }

    #[test]
    fn rejects_short_buffers() {
        assert!(Frame::new(10, 10, 40, PixelFormat::Bgrx, vec![0; 399]).is_err());
        assert!(Frame::new(10, 10, 39, PixelFormat::Bgrx, vec![0; 400]).is_err());
        assert!(Frame::new(0, 10, 40, PixelFormat::Bgrx, vec![]).is_err());
    }

    #[test]
    fn jpeg_roundtrip() {
        let f = bgrx(64, 48, |x, y| [(x * 4) as u8, (y * 5) as u8, 128]);
        let jpg = encode_jpeg(&to_rgb(&f, None), mjpeg_quality(4)).unwrap();
        assert_eq!(&jpg[..2], &[0xff, 0xd8]);
        assert_eq!(&jpg[jpg.len() - 2..], &[0xff, 0xd9]);
        let mut d = zune_jpeg::JpegDecoder::new(std::io::Cursor::new(&jpg));
        let px = d.decode().unwrap();
        let info = d.info().unwrap();
        assert_eq!((info.width, info.height), (64, 48));
        // Lossy, but close to the source at high quality.
        let (r, g, b) = (px[0] as i32, px[1] as i32, px[2] as i32);
        assert!(r.abs() < 12 && g.abs() < 12 && (b - 128).abs() < 12, "{r} {g} {b}");
    }

    #[test]
    fn png_roundtrip() {
        let f = bgrx(3, 2, |x, y| [x as u8 * 50, y as u8 * 100, 9]);
        let rgb = to_rgb(&f, None);
        let bytes = encode_png(&rgb).unwrap();
        assert_eq!(&bytes[1..4], b"PNG");
        let dec = png::Decoder::new(std::io::Cursor::new(&bytes));
        let mut r = dec.read_info().unwrap();
        let mut buf = vec![0; r.output_buffer_size().unwrap()];
        r.next_frame(&mut buf).unwrap();
        assert_eq!(buf, rgb.data);
        #[cfg(feature = "portal")]
        {
            let back = decode_png(&bytes).unwrap();
            assert_eq!(to_rgb(&back, None), rgb);
        }
    }

    #[test]
    fn ppm() {
        let mut bytes = b"P6\n# grim\n2 1\n255\n".to_vec();
        bytes.extend_from_slice(&[1, 2, 3, 4, 5, 6]);
        let f = decode_ppm(&bytes).unwrap();
        assert_eq!((f.width, f.height, f.format), (2, 1, PixelFormat::Rgb));
        assert_eq!(to_rgb(&f, None).data, vec![1, 2, 3, 4, 5, 6]);
        assert!(decode_ppm(b"P6 2 1 255\n\x01").is_err(), "short data");
        assert!(decode_ppm(b"P3 1 1 255\n1 2 3").is_err());
    }

    #[test]
    fn quality_scale() {
        assert_eq!(mjpeg_quality(2), 95);
        assert_eq!(mjpeg_quality(8), 79);
        assert_eq!(mjpeg_quality(31), 5);
        // Matches the agent's qscale(): client quality 80 → qscale 8 → back to ~80.
        assert!((mjpeg_quality(8) as i32 - 80).abs() <= 2);
    }

    #[test]
    fn base64_vectors() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64(&[0xff, 0xfe, 0xfd]), "//79");
    }

    #[test]
    fn fingerprints() {
        let a = bgrx(64, 64, |_, _| [1, 2, 3]);
        let mut b = a.clone();
        assert_eq!(a.fingerprint(), b.fingerprint());
        b.data[64 * 4 * 30 + 5] ^= 1;
        assert_ne!(a.fingerprint(), b.fingerprint());
    }
}
