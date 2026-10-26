//! Spectrum analyser bands: Hann window, radix-2 FFT, log-spaced bands.

/// Fills `out` with one level (0..1) per band from mono `samples`.
/// Uses the largest power-of-two prefix of `samples` (at least 64).
pub fn bands(samples: &[f32], sample_rate: u32, out: &mut [f32]) {
    for v in out.iter_mut() {
        *v = 0.0;
    }
    let mut n = 1usize;
    while n * 2 <= samples.len() {
        n *= 2;
    }
    if n < 64 || out.is_empty() || sample_rate == 0 {
        return;
    }
    let mut re: Vec<f32> = samples[samples.len() - n..]
        .iter()
        .enumerate()
        .map(|(i, &s)| {
            let w = 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / (n - 1) as f32).cos();
            s * w
        })
        .collect();
    let mut im = vec![0.0f32; n];
    fft(&mut re, &mut im);

    let sr = sample_rate as f32;
    let lo = 40.0f32;
    let hi = (sr / 2.0).min(16000.0).max(lo * 2.0);
    let full_scale = n as f32 / 4.0; // a full-scale sine through a Hann window
    let count = out.len();
    for (b, v) in out.iter_mut().enumerate() {
        let f0 = lo * (hi / lo).powf(b as f32 / count as f32);
        let f1 = lo * (hi / lo).powf((b + 1) as f32 / count as f32);
        // Low bands are narrower than one FFT bin; they share bins with their neighbours.
        let k0 = ((f0 * n as f32 / sr).floor() as usize).clamp(1, n / 2 - 1);
        let k1 = ((f1 * n as f32 / sr).ceil() as usize).clamp(k0 + 1, n / 2);
        let mut peak = 0.0f32;
        for k in k0..k1 {
            let mag = (re[k] * re[k] + im[k] * im[k]).sqrt();
            if mag > peak {
                peak = mag;
            }
        }
        let db = 20.0 * (peak / full_scale + 1e-9).log10();
        *v = ((db + 60.0) / 60.0).clamp(0.0, 1.0);
    }
}

/// In-place iterative radix-2 FFT. `re.len()` must be a power of two.
pub fn fft(re: &mut [f32], im: &mut [f32]) {
    let n = re.len();
    let mut j = 0usize;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j |= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= n {
        let ang = -2.0 * std::f32::consts::PI / len as f32;
        let (wr, wi) = (ang.cos(), ang.sin());
        let mut i = 0;
        while i < n {
            let (mut cr, mut ci) = (1.0f32, 0.0f32);
            for k in 0..len / 2 {
                let (ar, ai) = (re[i + k], im[i + k]);
                let (br, bi) = (re[i + k + len / 2], im[i + k + len / 2]);
                let (tr, ti) = (br * cr - bi * ci, br * ci + bi * cr);
                re[i + k] = ar + tr;
                im[i + k] = ai + ti;
                re[i + k + len / 2] = ar - tr;
                im[i + k + len / 2] = ai - ti;
                let ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
            i += len;
        }
        len <<= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fft_of_impulse_is_flat() {
        let mut re = vec![0.0f32; 8];
        let mut im = vec![0.0f32; 8];
        re[0] = 1.0;
        fft(&mut re, &mut im);
        for k in 0..8 {
            assert!((re[k] - 1.0).abs() < 1e-5 && im[k].abs() < 1e-5);
        }
    }

    #[test]
    fn sine_lights_up_its_band() {
        let sr = 44100;
        let f = 1000.0f32;
        let s: Vec<f32> = (0..2048).map(|i| (2.0 * std::f32::consts::PI * f * i as f32 / sr as f32).sin()).collect();
        let mut out = [0.0f32; 24];
        bands(&s, sr, &mut out);
        let loudest = out.iter().enumerate().max_by(|a, b| a.1.partial_cmp(b.1).unwrap()).unwrap().0;
        // the band whose range holds 1 kHz
        let lo = 40.0f32;
        let hi = 16000.0f32;
        let expected = ((f / lo).ln() / (hi / lo).ln() * 24.0).floor() as usize;
        assert!((loudest as i32 - expected as i32).abs() <= 1, "loudest {loudest}, expected {expected}");
        assert!(out[loudest] > 0.9);
        assert!(out[0] < 0.3 && out[23] < 0.3);
    }

    #[test]
    fn many_bands_with_long_window() {
        // the seek-bar (up to 140) and full-panel (64) styles use a 2048-sample window
        let sr = 48000;
        for &count in &[64usize, 90, 140] {
            let s: Vec<f32> = (0..2048).map(|i| (2.0 * std::f32::consts::PI * 440.0 * i as f32 / sr as f32).sin()).collect();
            let mut out = vec![0.0f32; count];
            bands(&s, sr, &mut out);
            assert!(out.iter().all(|v| v.is_finite() && (0.0..=1.0).contains(v)));
            let loudest = out.iter().enumerate().max_by(|a, b| a.1.partial_cmp(b.1).unwrap()).unwrap().0;
            let expected = ((440.0f32 / 40.0).ln() / (16000.0f32 / 40.0).ln() * count as f32) as i32;
            assert!((loudest as i32 - expected).abs() <= 2, "{count} bands: loudest {loudest}, expected {expected}");
            assert!(out[count - 1] < 0.3);
        }
    }

    #[test]
    fn silence_is_zero() {
        let mut out = [1.0f32; 24];
        bands(&[0.0; 1024], 48000, &mut out);
        assert!(out.iter().all(|&v| v == 0.0));
    }
}
