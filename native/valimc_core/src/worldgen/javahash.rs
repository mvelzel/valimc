//! A `java.util.HashSet<BlockPos>` with Java's iteration order (VMC-025):
//! trees and vegetation patches collect positions in hash sets, and vanilla's
//! results depend on the order those iterate.
//!
//! `HashMap` keeps a table of bins and iterates them in table order. A bin is
//! a linked list in insertion order; once a bin holds eight entries and
//! another arrives, the table doubles while it has fewer than 64 bins, and
//! otherwise the bin becomes a red-black tree ordered by hash. A tree bin
//! still iterates its linked list, but that list changes with the tree: the
//! root moves to its front after building and after each insertion, a new
//! entry is linked right after its tree parent, and a resize splits each bin
//! into a low and a high bin in list order, rebuilding a half as a tree only
//! when it keeps more than six entries and the other half is not empty.
//! Entries with equal hashes in a tree bin would be ordered by identity hash
//! codes; the set records that (`unordered`) instead of guessing, and block
//! positions within a feature never collide that way.

/// `Vec3i.hashCode`.
pub fn block_pos_hash(pos: [i32; 3]) -> i32 {
    pos[1]
        .wrapping_add(pos[2].wrapping_mul(31))
        .wrapping_mul(31)
        .wrapping_add(pos[0])
}

/// `HashMap.hash`.
fn spread(hash: i32) -> i32 {
    hash ^ ((hash as u32) >> 16) as i32
}

const NONE: u32 = u32::MAX;

#[derive(Clone, Debug)]
struct Node {
    pos: [i32; 3],
    hash: i32,
    /// The bin's linked list.
    next: u32,
    prev: u32,
    /// Tree links, meaningful while the bin is a tree.
    parent: u32,
    left: u32,
    right: u32,
    red: bool,
}

#[derive(Clone, Debug)]
pub struct JavaHashSet {
    nodes: Vec<Node>,
    free: Vec<u32>,
    heads: Vec<u32>,
    trees: Vec<bool>,
    size: usize,
    /// Set when Java's order would depend on identity hash codes.
    pub unordered: bool,
    /// How often a bin became a tree (for the parity checks' coverage).
    pub treeified: usize,
}

impl Default for JavaHashSet {
    fn default() -> Self {
        Self::new()
    }
}

impl JavaHashSet {
    /// `new HashSet<>()`: 16 bins (allocated on the first insertion in Java,
    /// the same size either way).
    pub fn new() -> JavaHashSet {
        JavaHashSet {
            nodes: Vec::new(),
            free: Vec::new(),
            heads: vec![NONE; 16],
            trees: vec![false; 16],
            size: 0,
            unordered: false,
            treeified: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.size
    }

    pub fn is_empty(&self) -> bool {
        self.size == 0
    }

    fn bin(&self, hash: i32) -> usize {
        (hash as u32 as usize) & (self.heads.len() - 1)
    }

    fn n(&self, i: u32) -> &Node {
        &self.nodes[i as usize]
    }

    fn m(&mut self, i: u32) -> &mut Node {
        &mut self.nodes[i as usize]
    }

    fn find(&self, pos: [i32; 3]) -> Option<u32> {
        let mut e = self.heads[self.bin(spread(block_pos_hash(pos)))];
        while e != NONE {
            if self.n(e).pos == pos {
                return Some(e);
            }
            e = self.n(e).next;
        }
        None
    }

    pub fn contains(&self, pos: [i32; 3]) -> bool {
        self.find(pos).is_some()
    }

    fn alloc(&mut self, pos: [i32; 3], hash: i32) -> u32 {
        let node = Node {
            pos,
            hash,
            next: NONE,
            prev: NONE,
            parent: NONE,
            left: NONE,
            right: NONE,
            red: false,
        };
        match self.free.pop() {
            Some(i) => {
                self.nodes[i as usize] = node;
                i
            }
            None => {
                self.nodes.push(node);
                (self.nodes.len() - 1) as u32
            }
        }
    }

    /// `add`; whether the set changed.
    pub fn insert(&mut self, pos: [i32; 3]) -> bool {
        if self.contains(pos) {
            return false;
        }
        let hash = spread(block_pos_hash(pos));
        let index = self.bin(hash);
        let head = self.heads[index];
        if head == NONE {
            self.heads[index] = self.alloc(pos, hash);
        } else if self.trees[index] {
            self.put_tree(index, pos, hash);
        } else {
            let mut last = head;
            let mut count = 1;
            while self.n(last).next != NONE {
                last = self.n(last).next;
                count += 1;
            }
            let x = self.alloc(pos, hash);
            self.m(last).next = x;
            self.m(x).prev = last;
            // `putVal`: appending to a bin of eight treeifies it, which in
            // a small table doubles the table instead.
            if count >= 8 {
                if self.heads.len() < 64 {
                    self.resize();
                } else {
                    self.treeify(index);
                    self.treeified += 1;
                }
            }
        }
        self.size += 1;
        if self.size > self.heads.len() * 3 / 4 {
            self.resize();
        }
        true
    }

    /// The tree order: by hash, equal hashes undecidable.
    fn direction(&mut self, h: i32, ph: i32) -> bool {
        if ph == h {
            self.unordered = true;
        }
        // `dir <= 0` goes left.
        ph >= h
    }

    /// `TreeNode.putTreeVal` for a position not in the set.
    fn put_tree(&mut self, index: usize, pos: [i32; 3], hash: i32) {
        let mut p = self.root_of(self.heads[index]);
        loop {
            let left = self.direction(hash, self.n(p).hash);
            let child = if left {
                self.n(p).left
            } else {
                self.n(p).right
            };
            if child != NONE {
                p = child;
                continue;
            }
            let after = self.n(p).next;
            let x = self.alloc(pos, hash);
            if left {
                self.m(p).left = x;
            } else {
                self.m(p).right = x;
            }
            self.m(p).next = x;
            self.m(x).parent = p;
            self.m(x).prev = p;
            self.m(x).next = after;
            if after != NONE {
                self.m(after).prev = x;
            }
            let root = self.root_of(p);
            let root = self.balance_insertion(root, x);
            self.move_root_to_front(index, root);
            return;
        }
    }

    fn root_of(&self, mut x: u32) -> u32 {
        while self.n(x).parent != NONE {
            x = self.n(x).parent;
        }
        x
    }

    /// `TreeNode.treeify` of the bin's list, keeping the list order apart
    /// from the root moving to the front.
    fn treeify(&mut self, index: usize) {
        self.trees[index] = true;
        let mut root = NONE;
        let mut x = self.heads[index];
        while x != NONE {
            let next = self.n(x).next;
            self.m(x).left = NONE;
            self.m(x).right = NONE;
            if root == NONE {
                self.m(x).parent = NONE;
                self.m(x).red = false;
                root = x;
            } else {
                let h = self.n(x).hash;
                let mut p = root;
                loop {
                    let left = self.direction(h, self.n(p).hash);
                    let child = if left {
                        self.n(p).left
                    } else {
                        self.n(p).right
                    };
                    if child == NONE {
                        self.m(x).parent = p;
                        if left {
                            self.m(p).left = x;
                        } else {
                            self.m(p).right = x;
                        }
                        root = self.balance_insertion(root, x);
                        break;
                    }
                    p = child;
                }
            }
            x = next;
        }
        self.move_root_to_front(index, root);
    }

    fn move_root_to_front(&mut self, index: usize, root: u32) {
        let first = self.heads[index];
        if root == first {
            return;
        }
        self.heads[index] = root;
        let (rp, rn) = (self.n(root).prev, self.n(root).next);
        if rn != NONE {
            self.m(rn).prev = rp;
        }
        if rp != NONE {
            self.m(rp).next = rn;
        }
        if first != NONE {
            self.m(first).prev = root;
        }
        self.m(root).next = first;
        self.m(root).prev = NONE;
    }

    fn rotate_left(&mut self, mut root: u32, p: u32) -> u32 {
        if p == NONE || self.n(p).right == NONE {
            return root;
        }
        let r = self.n(p).right;
        let rl = self.n(r).left;
        self.m(p).right = rl;
        if rl != NONE {
            self.m(rl).parent = p;
        }
        let pp = self.n(p).parent;
        self.m(r).parent = pp;
        if pp == NONE {
            root = r;
            self.m(r).red = false;
        } else if self.n(pp).left == p {
            self.m(pp).left = r;
        } else {
            self.m(pp).right = r;
        }
        self.m(r).left = p;
        self.m(p).parent = r;
        root
    }

    fn rotate_right(&mut self, mut root: u32, p: u32) -> u32 {
        if p == NONE || self.n(p).left == NONE {
            return root;
        }
        let l = self.n(p).left;
        let lr = self.n(l).right;
        self.m(p).left = lr;
        if lr != NONE {
            self.m(lr).parent = p;
        }
        let pp = self.n(p).parent;
        self.m(l).parent = pp;
        if pp == NONE {
            root = l;
            self.m(l).red = false;
        } else if self.n(pp).right == p {
            self.m(pp).right = l;
        } else {
            self.m(pp).left = l;
        }
        self.m(l).right = p;
        self.m(p).parent = l;
        root
    }

    fn red(&self, x: u32) -> bool {
        x != NONE && self.n(x).red
    }

    fn parent(&self, x: u32) -> u32 {
        if x == NONE {
            NONE
        } else {
            self.n(x).parent
        }
    }

    fn balance_insertion(&mut self, mut root: u32, mut x: u32) -> u32 {
        self.m(x).red = true;
        loop {
            let mut xp = self.n(x).parent;
            if xp == NONE {
                self.m(x).red = false;
                return x;
            }
            let mut xpp = self.n(xp).parent;
            if !self.n(xp).red || xpp == NONE {
                return root;
            }
            let xppl = self.n(xpp).left;
            if xp == xppl {
                let xppr = self.n(xpp).right;
                if self.red(xppr) {
                    self.m(xppr).red = false;
                    self.m(xp).red = false;
                    self.m(xpp).red = true;
                    x = xpp;
                } else {
                    if x == self.n(xp).right {
                        x = xp;
                        root = self.rotate_left(root, x);
                        xp = self.n(x).parent;
                        xpp = self.parent(xp);
                    }
                    if xp != NONE {
                        self.m(xp).red = false;
                        if xpp != NONE {
                            self.m(xpp).red = true;
                            root = self.rotate_right(root, xpp);
                        }
                    }
                }
            } else if self.red(xppl) {
                self.m(xppl).red = false;
                self.m(xp).red = false;
                self.m(xpp).red = true;
                x = xpp;
            } else {
                if x == self.n(xp).left {
                    x = xp;
                    root = self.rotate_right(root, x);
                    xp = self.n(x).parent;
                    xpp = self.parent(xp);
                }
                if xp != NONE {
                    self.m(xp).red = false;
                    if xpp != NONE {
                        self.m(xpp).red = true;
                        root = self.rotate_left(root, xpp);
                    }
                }
            }
        }
    }

    fn balance_deletion(&mut self, mut root: u32, mut x: u32) -> u32 {
        loop {
            if x == NONE || x == root {
                return root;
            }
            let mut xp = self.n(x).parent;
            if xp == NONE {
                self.m(x).red = false;
                return x;
            }
            if self.n(x).red {
                self.m(x).red = false;
                return root;
            }
            let xpl = self.n(xp).left;
            if xpl == x {
                let mut xpr = self.n(xp).right;
                if self.red(xpr) {
                    self.m(xpr).red = false;
                    self.m(xp).red = true;
                    root = self.rotate_left(root, xp);
                    xp = self.n(x).parent;
                    xpr = if xp == NONE { NONE } else { self.n(xp).right };
                }
                if xpr == NONE {
                    x = xp;
                } else {
                    let (sl, sr) = (self.n(xpr).left, self.n(xpr).right);
                    if !self.red(sr) && !self.red(sl) {
                        self.m(xpr).red = true;
                        x = xp;
                    } else {
                        if !self.red(sr) {
                            if sl != NONE {
                                self.m(sl).red = false;
                            }
                            self.m(xpr).red = true;
                            root = self.rotate_right(root, xpr);
                            xp = self.n(x).parent;
                            xpr = if xp == NONE { NONE } else { self.n(xp).right };
                        }
                        if xpr != NONE {
                            let red = xp != NONE && self.n(xp).red;
                            self.m(xpr).red = red;
                            let sr = self.n(xpr).right;
                            if sr != NONE {
                                self.m(sr).red = false;
                            }
                        }
                        if xp != NONE {
                            self.m(xp).red = false;
                            root = self.rotate_left(root, xp);
                        }
                        x = root;
                    }
                }
            } else {
                let mut xpl = xpl;
                if self.red(xpl) {
                    self.m(xpl).red = false;
                    self.m(xp).red = true;
                    root = self.rotate_right(root, xp);
                    xp = self.n(x).parent;
                    xpl = if xp == NONE { NONE } else { self.n(xp).left };
                }
                if xpl == NONE {
                    x = xp;
                } else {
                    let (sl, sr) = (self.n(xpl).left, self.n(xpl).right);
                    if !self.red(sl) && !self.red(sr) {
                        self.m(xpl).red = true;
                        x = xp;
                    } else {
                        if !self.red(sl) {
                            if sr != NONE {
                                self.m(sr).red = false;
                            }
                            self.m(xpl).red = true;
                            root = self.rotate_left(root, xpl);
                            xp = self.n(x).parent;
                            xpl = if xp == NONE { NONE } else { self.n(xp).left };
                        }
                        if xpl != NONE {
                            let red = xp != NONE && self.n(xp).red;
                            self.m(xpl).red = red;
                            let sl = self.n(xpl).left;
                            if sl != NONE {
                                self.m(sl).red = false;
                            }
                        }
                        if xp != NONE {
                            self.m(xp).red = false;
                            root = self.rotate_right(root, xp);
                        }
                        x = root;
                    }
                }
            }
        }
    }

    /// `TreeNode.removeTreeNode`; `movable` as `HashSet.remove` passes it,
    /// not an iterator's removal.
    fn remove_tree_node(&mut self, index: usize, p: u32, movable: bool) {
        let old_first = self.heads[index];
        let (succ, pred) = (self.n(p).next, self.n(p).prev);
        if pred == NONE {
            self.heads[index] = succ;
        } else {
            self.m(pred).next = succ;
        }
        if succ != NONE {
            self.m(succ).prev = pred;
        }
        let first = self.heads[index];
        if first == NONE {
            self.trees[index] = false;
            return;
        }
        let mut root = self.root_of(old_first);
        if movable {
            let rl = self.n(root).left;
            if self.n(root).right == NONE || rl == NONE || self.n(rl).left == NONE {
                // Too small: back to a list, in list order.
                self.trees[index] = false;
                return;
            }
        }
        let (pl, pr) = (self.n(p).left, self.n(p).right);
        let replacement = if pl != NONE && pr != NONE {
            let mut s = pr;
            while self.n(s).left != NONE {
                s = self.n(s).left;
            }
            let c = self.n(s).red;
            let pred_red = self.n(p).red;
            self.m(s).red = pred_red;
            self.m(p).red = c;
            let sr = self.n(s).right;
            let pp = self.n(p).parent;
            if s == pr {
                self.m(p).parent = s;
                self.m(s).right = p;
            } else {
                let sp = self.n(s).parent;
                self.m(p).parent = sp;
                if sp != NONE {
                    if s == self.n(sp).left {
                        self.m(sp).left = p;
                    } else {
                        self.m(sp).right = p;
                    }
                }
                self.m(s).right = pr;
                if pr != NONE {
                    self.m(pr).parent = s;
                }
            }
            self.m(p).left = NONE;
            self.m(p).right = sr;
            if sr != NONE {
                self.m(sr).parent = p;
            }
            self.m(s).left = pl;
            if pl != NONE {
                self.m(pl).parent = s;
            }
            self.m(s).parent = pp;
            if pp == NONE {
                root = s;
            } else if p == self.n(pp).left {
                self.m(pp).left = s;
            } else {
                self.m(pp).right = s;
            }
            if sr != NONE {
                sr
            } else {
                p
            }
        } else if pl != NONE {
            pl
        } else if pr != NONE {
            pr
        } else {
            p
        };
        if replacement != p {
            let pp = self.n(p).parent;
            self.m(replacement).parent = pp;
            if pp == NONE {
                root = replacement;
                self.m(replacement).red = false;
            } else if p == self.n(pp).left {
                self.m(pp).left = replacement;
            } else {
                self.m(pp).right = replacement;
            }
            self.m(p).left = NONE;
            self.m(p).right = NONE;
            self.m(p).parent = NONE;
        }
        let r = if self.n(p).red {
            root
        } else {
            self.balance_deletion(root, replacement)
        };
        if replacement == p {
            let pp = self.n(p).parent;
            self.m(p).parent = NONE;
            if pp != NONE {
                if p == self.n(pp).left {
                    self.m(pp).left = NONE;
                } else if p == self.n(pp).right {
                    self.m(pp).right = NONE;
                }
            }
        }
        if movable {
            self.move_root_to_front(index, r);
        }
    }

    fn remove_node(&mut self, x: u32, movable: bool) {
        let index = self.bin(self.n(x).hash);
        if self.trees[index] {
            self.remove_tree_node(index, x, movable);
        } else {
            let (prev, next) = (self.n(x).prev, self.n(x).next);
            if prev == NONE {
                self.heads[index] = next;
            } else {
                self.m(prev).next = next;
            }
            if next != NONE {
                self.m(next).prev = prev;
            }
        }
        self.free.push(x);
        self.size -= 1;
    }

    /// `remove`; whether the set changed.
    pub fn remove(&mut self, pos: [i32; 3]) -> bool {
        match self.find(pos) {
            Some(x) => {
                self.remove_node(x, true);
                true
            }
            None => false,
        }
    }

    /// The first element in iteration order, removed through the iterator.
    pub fn poll_first(&mut self) -> Option<[i32; 3]> {
        let x = *self.heads.iter().find(|&&h| h != NONE)?;
        let pos = self.n(x).pos;
        self.remove_node(x, false);
        Some(pos)
    }

    /// `HashMap.resize`: twice the bins, each bin split in list order.
    fn resize(&mut self) {
        let old = self.heads.len();
        let n = old * 2;
        let old_heads = std::mem::replace(&mut self.heads, vec![NONE; n]);
        let old_trees = std::mem::replace(&mut self.trees, vec![false; n]);
        for (j, &head) in old_heads.iter().enumerate() {
            let (mut lo, mut hi) = (Vec::new(), Vec::new());
            let mut e = head;
            while e != NONE {
                if (self.n(e).hash as u32 as usize) & old == 0 {
                    lo.push(e);
                } else {
                    hi.push(e);
                }
                e = self.n(e).next;
            }
            for (index, list, other) in [(j, &lo, hi.is_empty()), (j + old, &hi, lo.is_empty())] {
                if list.is_empty() {
                    continue;
                }
                for (k, &x) in list.iter().enumerate() {
                    self.m(x).prev = if k == 0 { NONE } else { list[k - 1] };
                    self.m(x).next = if k + 1 == list.len() {
                        NONE
                    } else {
                        list[k + 1]
                    };
                }
                self.heads[index] = list[0];
                if old_trees[j] {
                    if list.len() <= 6 {
                        // `untreeify`.
                    } else if other {
                        // The whole tree moved as it is.
                        self.trees[index] = true;
                    } else {
                        self.treeify(index);
                    }
                }
            }
        }
    }

    /// The first element in iteration order.
    pub fn first(&self) -> Option<[i32; 3]> {
        self.iter().next()
    }

    /// The elements in Java's iteration order.
    pub fn iter(&self) -> impl Iterator<Item = [i32; 3]> + '_ {
        self.heads.iter().flat_map(move |&head| {
            let mut e = head;
            std::iter::from_fn(move || {
                if e == NONE {
                    return None;
                }
                let pos = self.n(e).pos;
                e = self.n(e).next;
                Some(pos)
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_matches_vec3i() {
        assert_eq!(block_pos_hash([1, 2, 3]), (2 + 3 * 31) * 31 + 1);
        assert_eq!(
            block_pos_hash([-30_000_000, 319, 30_000_000]),
            319i32
                .wrapping_add(30_000_000i32.wrapping_mul(31))
                .wrapping_mul(31)
                .wrapping_add(-30_000_000)
        );
    }

    #[test]
    fn keeps_every_element_through_trees_and_removals() {
        let mut set = JavaHashSet::new();
        let mut want = std::collections::HashSet::new();
        let mut state = 7u64;
        let mut next = || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (state >> 33) as i32
        };
        for _ in 0..4000 {
            // Multiples of 4096 share a bin until the table has 4096 bins.
            let pos = if next() % 2 == 0 {
                [(next() % 40) * 4096, 0, 0]
            } else {
                [next() % 9, next() % 40, next() % 9]
            };
            if next() % 3 == 0 {
                assert_eq!(set.remove(pos), want.remove(&pos));
            } else if next() % 5 == 0 {
                if let Some(p) = set.poll_first() {
                    assert!(want.remove(&p));
                }
            } else {
                assert_eq!(set.insert(pos), want.insert(pos));
            }
            assert_eq!(set.len(), want.len());
        }
        let got: std::collections::HashSet<_> = set.iter().collect();
        assert_eq!(got, want);
        assert!(set.treeified > 0);
    }
}
