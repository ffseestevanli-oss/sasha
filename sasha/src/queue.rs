//! The play queue: a list of track indices, an optional shuffled order,
//! and repeat modes.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Repeat {
    Off,
    All,
    One,
}

impl Repeat {
    pub fn from_u32(v: u32) -> Self {
        match v {
            1 => Repeat::All,
            2 => Repeat::One,
            _ => Repeat::Off,
        }
    }
}

pub struct Queue {
    base: Vec<u32>,
    order: Vec<u32>,
    pos: usize,
    shuffle: bool,
    repeat: Repeat,
    rng: u64,
}

impl Queue {
    pub fn new(seed: u64) -> Self {
        Queue { base: Vec::new(), order: Vec::new(), pos: 0, shuffle: false, repeat: Repeat::Off, rng: seed | 1 }
    }

    fn rand(&mut self) -> u64 {
        // xorshift64*
        let mut x = self.rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.rng = x;
        x.wrapping_mul(0x2545F4914F6CDD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.rand() % n as u64) as usize
    }

    fn shuffled(&mut self, items: &[u32]) -> Vec<u32> {
        let mut v = items.to_vec();
        for i in (1..v.len()).rev() {
            let j = self.below(i + 1);
            v.swap(i, j);
        }
        v
    }

    /// Replaces the queue. `start` is a position in `tracks`; with shuffle on,
    /// that track plays first (or a random one when `start` is None).
    pub fn set(&mut self, tracks: Vec<u32>, start: Option<usize>, shuffle: bool) -> Option<u32> {
        self.shuffle = shuffle;
        self.base = tracks;
        self.pos = 0;
        if self.base.is_empty() {
            self.order.clear();
            return None;
        }
        if shuffle {
            let first_pos = match start {
                Some(s) if s < self.base.len() => s,
                _ => self.below(self.base.len()),
            };
            let first = self.base[first_pos];
            let mut rest = self.base.clone();
            rest.remove(first_pos);
            let mut order = vec![first];
            order.extend(self.shuffled(&rest));
            self.order = order;
        } else {
            self.order = self.base.clone();
            self.pos = start.filter(|&s| s < self.order.len()).unwrap_or(0);
        }
        self.current()
    }

    pub fn current(&self) -> Option<u32> {
        self.order.get(self.pos).copied()
    }

    pub fn len(&self) -> usize {
        self.order.len()
    }

    pub fn shuffle(&self) -> bool {
        self.shuffle
    }

    pub fn set_repeat(&mut self, r: Repeat) {
        self.repeat = r;
    }

    /// Moves on. `user` is true for the Next button, false when a track ended.
    pub fn next(&mut self, user: bool) -> Option<u32> {
        if self.order.is_empty() {
            return None;
        }
        if self.repeat == Repeat::One && !user {
            return self.current();
        }
        if self.pos + 1 < self.order.len() {
            self.pos += 1;
            return self.current();
        }
        if self.repeat == Repeat::Off {
            return None;
        }
        if self.shuffle {
            let last = self.current();
            let base = self.base.clone();
            let mut o = self.shuffled(&base);
            if o.len() > 1 && o.first().copied() == last {
                let n = o.len();
                o.swap(0, n - 1);
            }
            self.order = o;
        }
        self.pos = 0;
        self.current()
    }

    pub fn prev(&mut self) -> Option<u32> {
        if self.order.is_empty() {
            return None;
        }
        if self.pos > 0 {
            self.pos -= 1;
        } else if self.repeat != Repeat::Off {
            self.pos = self.order.len() - 1;
        }
        self.current()
    }

    /// What `next(false)` would play, without moving.
    pub fn peek(&self) -> Option<u32> {
        if self.order.is_empty() {
            return None;
        }
        if self.repeat == Repeat::One {
            return self.current();
        }
        if self.pos + 1 < self.order.len() {
            return self.order.get(self.pos + 1).copied();
        }
        if self.repeat == Repeat::All && !self.shuffle {
            return self.order.first().copied();
        }
        None
    }

    /// "Play next": puts `tracks` right after the current one, in order.
    /// They stay there if shuffle is turned off later.
    pub fn insert_next(&mut self, tracks: &[u32]) -> Option<u32> {
        if tracks.is_empty() {
            return self.current();
        }
        if self.order.is_empty() {
            return self.set(tracks.to_vec(), Some(0), false);
        }
        let cur = self.current();
        let at = self.pos + 1;
        for (k, &t) in tracks.iter().enumerate() {
            self.order.insert(at + k, t);
        }
        let base_at = cur.and_then(|c| self.base.iter().position(|&x| x == c)).map(|p| p + 1).unwrap_or(self.base.len());
        for (k, &t) in tracks.iter().enumerate() {
            self.base.insert(base_at + k, t);
        }
        self.current()
    }

    /// Turns shuffle on or off, keeping the current track playing.
    pub fn set_shuffle(&mut self, on: bool) {
        if on == self.shuffle {
            return;
        }
        self.shuffle = on;
        if self.order.is_empty() {
            return;
        }
        let cur = self.current();
        if on {
            let mut rest = self.base.clone();
            if let Some(c) = cur {
                if let Some(p) = rest.iter().position(|&t| t == c) {
                    rest.remove(p);
                }
            }
            let mut order: Vec<u32> = cur.into_iter().collect();
            order.extend(self.shuffled(&rest));
            self.order = order;
            self.pos = 0;
        } else {
            self.order = self.base.clone();
            self.pos = cur.and_then(|c| self.base.iter().position(|&t| t == c)).unwrap_or(0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plays_in_order_and_stops() {
        let mut q = Queue::new(7);
        assert_eq!(q.set(vec![10, 11, 12], Some(1), false), Some(11));
        assert_eq!(q.peek(), Some(12));
        assert_eq!(q.next(false), Some(12));
        assert_eq!(q.next(false), None);
        assert_eq!(q.prev(), Some(11));
    }

    #[test]
    fn repeat_modes() {
        let mut q = Queue::new(7);
        q.set(vec![1, 2], None, false);
        q.set_repeat(Repeat::All);
        assert_eq!(q.next(false), Some(2));
        assert_eq!(q.peek(), Some(1));
        assert_eq!(q.next(false), Some(1));
        q.set_repeat(Repeat::One);
        assert_eq!(q.next(false), Some(1));
        assert_eq!(q.next(true), Some(2));
    }

    #[test]
    fn shuffle_plays_everything_once() {
        let mut q = Queue::new(12345);
        let all: Vec<u32> = (0..100).collect();
        let first = q.set(all.clone(), None, true).unwrap();
        let mut seen = vec![first];
        while let Some(t) = q.next(false) {
            seen.push(t);
        }
        assert_eq!(seen.len(), 100);
        let mut sorted = seen.clone();
        sorted.sort();
        assert_eq!(sorted, all);
        assert_ne!(seen, all, "should not come out in order");
    }

    #[test]
    fn shuffle_starts_with_chosen_track() {
        let mut q = Queue::new(99);
        assert_eq!(q.set(vec![5, 6, 7, 8], Some(2), true), Some(7));
    }

    #[test]
    fn toggling_shuffle_keeps_current() {
        let mut q = Queue::new(3);
        q.set((0..20).collect(), Some(4), false);
        q.set_shuffle(true);
        assert_eq!(q.current(), Some(4));
        assert_eq!(q.len(), 20);
        q.next(true);
        let cur = q.current().unwrap();
        q.set_shuffle(false);
        assert_eq!(q.current(), Some(cur));
        assert_eq!(q.peek(), if cur < 19 { Some(cur + 1) } else { None });
    }

    #[test]
    fn play_next_goes_after_current() {
        let mut q = Queue::new(5);
        q.set(vec![1, 2, 3, 4], Some(1), false);
        q.insert_next(&[8, 9]);
        assert_eq!(q.current(), Some(2));
        let mut rest = Vec::new();
        while let Some(t) = q.next(false) {
            rest.push(t);
        }
        assert_eq!(rest, vec![8, 9, 3, 4]);

        // with shuffle on, the inserted songs still come next
        let mut q = Queue::new(77);
        q.set((0..50).collect(), None, true);
        q.next(true);
        let cur = q.current().unwrap();
        q.insert_next(&[100, 101]);
        assert_eq!(q.current(), Some(cur));
        assert_eq!(q.next(false), Some(100));
        assert_eq!(q.next(false), Some(101));
        assert_eq!(q.len(), 52);

        // on an empty queue it simply starts playing them
        let mut q = Queue::new(1);
        assert_eq!(q.insert_next(&[7, 6]), Some(7));
        assert_eq!(q.next(false), Some(6));
    }

    #[test]
    fn repeat_all_shuffle_never_repeats_back_to_back() {
        let mut q = Queue::new(42);
        q.set(vec![1, 2], None, true);
        q.set_repeat(Repeat::All);
        let mut last = q.current().unwrap();
        for _ in 0..50 {
            let n = q.next(false).unwrap();
            assert_ne!(n, last);
            last = n;
        }
    }
}
