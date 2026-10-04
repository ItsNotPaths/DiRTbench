package nefs

// NeFS 1.5.1 as DiRT 3 ships it in win_000.nfs: an RSA-signed intro, then
// AES-256-ECB header and data, no compression. Map: opencodies/docs/checksums.md.
//
// Edits keep every file its size, so the signed header never changes. The game
// samples each block's CRC16 from that header, so a write puts it back by
// changing spare bytes the caller names (see `restore_crc16`).

import "core:crypto/aes"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:hash"
import "core:math/big"
import "core:slice"

// DiRT 3's public key (exe VA 0xeab668), little-endian.
@(private = "file")
DIRT3_KEY := [128]u8 {
	0xe1, 0x20, 0x90, 0x92, 0xb1, 0x24, 0xe2, 0xf4, 0x98, 0xba, 0xc1, 0xf4, 0x8e, 0xf9, 0x26, 0x5b,
	0x16, 0xfd, 0x24, 0xa4, 0xb7, 0xd6, 0x64, 0xb0, 0xd7, 0xa4, 0x56, 0x8d, 0x46, 0x95, 0xcb, 0x0c,
	0xd1, 0x1a, 0x63, 0x66, 0x1d, 0x96, 0x08, 0x43, 0x2b, 0xc0, 0xcc, 0xfa, 0x74, 0xa5, 0xde, 0x1f,
	0x8b, 0x8a, 0x68, 0x3a, 0xde, 0xc9, 0x72, 0x45, 0x91, 0x07, 0x4b, 0x4a, 0xc4, 0x05, 0x0e, 0xe4,
	0x81, 0xb0, 0x5d, 0x52, 0x79, 0x39, 0x0d, 0x09, 0xae, 0xb0, 0x9d, 0xf7, 0xcc, 0x09, 0xa1, 0xc9,
	0x8e, 0xfb, 0x24, 0xe7, 0x1e, 0xc7, 0xac, 0x6d, 0x88, 0x90, 0x0b, 0x12, 0x71, 0x34, 0x1c, 0xc4,
	0x2b, 0x8f, 0xdc, 0x4d, 0x70, 0x17, 0x30, 0x38, 0x5c, 0xf2, 0xfb, 0xc9, 0x84, 0xa1, 0xe7, 0xc9,
	0x06, 0x14, 0x35, 0xd9, 0x1e, 0xf4, 0x7e, 0x98, 0xe9, 0x4e, 0x56, 0x35, 0xba, 0x23, 0x14, 0x8c,
}

@(private = "file")
MAGIC :: 0x5346654E // "NeFS"
@(private = "file")
VERSION :: 0x10501

Archive :: struct {
	raw:    []u8, // the whole file; writes land here
	header: []u8, // decrypted, addressed like the game's own copy
	words:  [32]u32, // the unscrambled intro
	aes:    aes.Context_ECB,
}

// A byte the caller does not care about: its offset in the file, and a value
// it may take instead.
Spare :: struct {
	at:  int,
	alt: u8,
}

@(private = "file")
Block :: struct {
	index:      int,
	start, end: int, // offsets in raw
}

@(private = "file")
Entry :: struct {
	size:   int,
	blocks: []Block,
}

// Decode the header of `raw`. The archive edits `raw` in place.
open :: proc(raw: []u8) -> (a: Archive, msg: string, ok: bool) {
	if len(raw) < 128 {
		return a, "archive is too short", false
	}
	a.raw = raw
	if !rsa_intro(raw[:128], &a.words) {
		return a, "archive is not a DiRT 3 signed NeFS 1.5.1 archive", false
	}
	w := &a.words
	unscramble(w)
	header_size := int(w[1])
	if w[0] != MAGIC || w[2] != VERSION || header_size > len(raw) || (header_size - 128) % 16 != 0 {
		return a, "archive is not a DiRT 3 signed NeFS 1.5.1 archive", false
	}

	intro: [128]u8
	for word, i in w {
		endian.unchecked_put_u32le(intro[4 * i:], word)
	}
	key, key_ok := hex.decode(intro[0x3C:0x7C], context.temp_allocator)
	if !key_ok {
		return a, "archive key is not hex", false
	}
	aes.init_ecb(&a.aes, key)

	// The game copies 126 intro bytes, then decrypts the rest right after them.
	a.header = make([]u8, header_size - 2)
	copy(a.header, intro[:126])
	ecb(&a.aes, a.header[126:], raw[128:header_size], decrypt = true)
	return a, "", true
}

close :: proc(a: ^Archive) {
	delete(a.header)
	aes.reset_ecb(&a.aes)
}

// The plaintext of `name` (a bare file name, as the archive stores it).
read :: proc(a: ^Archive, name: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	entry := find(a, name) or_return
	plain := decrypt_entry(a, entry, allocator)
	return plain[:entry.size], true
}

// Replace `name` with `data`, which must be the same size. `spares` are the
// offsets in `data` that may change to restore a block's CRC16.
write :: proc(a: ^Archive, name: string, data: []u8, spares: []Spare) -> (msg: string, ok: bool) {
	entry, found := find(a, name)
	if !found {
		return fmt.tprintf("%s is not in the archive", name), false
	}
	if len(data) != entry.size {
		return fmt.tprintf("%s must stay %d bytes, got %d", name, entry.size, len(data)), false
	}
	plain := decrypt_entry(a, entry, context.temp_allocator)
	copy(plain, data)

	// Encrypt everything first, so a refusal leaves the archive untouched.
	ciphers := make([][]u8, len(entry.blocks), context.temp_allocator)
	at := 0
	for b, k in entry.blocks {
		n := b.end - b.start
		block_plain := plain[at:at + n]
		block_spares := make([dynamic]Spare, context.temp_allocator)
		for s in spares {
			if s.at >= at && s.at < at + n {
				append(&block_spares, Spare{s.at - at, s.alt})
			}
		}
		// The padding after the file's end is unread.
		for i in max(entry.size - at, 0) ..< n {
			append(&block_spares, Spare{i, block_plain[i] ~ 1})
		}
		slice.sort_by_key(block_spares[:], proc(s: Spare) -> int {return s.at})

		cipher := make([]u8, n, context.temp_allocator)
		ecb(&a.aes, cipher, block_plain)
		stored := stored_crc16(a, b)
		if crc16(cipher) != stored {
			if !restore_crc16(a, block_plain, cipher, block_spares[:], stored) {
				return fmt.tprintf("%s: not enough spare bytes to keep block %d's checksum", name, b.index), false
			}
		}
		ciphers[k] = cipher
		at += n
	}
	for b, k in entry.blocks {
		copy(a.raw[b.start:b.end], ciphers[k])
	}
	return "", true
}

// Whether every block of `name` matches the CRC16 the signed header holds.
checksums_hold :: proc(a: ^Archive, name: string) -> bool {
	entry := find(a, name) or_return
	for b in entry.blocks {
		if crc16(a.raw[b.start:b.end]) != stored_crc16(a, b) {
			return false
		}
	}
	return true
}

@(private = "file")
stored_crc16 :: proc(a: ^Archive, b: Block) -> u16 {
	return endian.unchecked_get_u16le(a.header[block_table(a) + 8 * b.index + 6:])
}

// The CRC16 the game samples: both halves of the ciphertext's CRC32, added.
crc16 :: proc(cipher: []u8) -> u16 {
	c := hash.crc32(cipher)
	return u16(c) + u16(c >> 16)
}

// An AES block holding spares can be re-encrypted in many variants, one per
// subset of its spare bytes. CRC32 is affine at a fixed length, so variants in
// separate AES blocks move the CRC32 by independent XORs. A 16-bit target needs
// about 65k tries: take AES blocks, last first, until there are 2^20
// combinations, then search them.
@(private = "file")
restore_crc16 :: proc(a: ^Archive, plain, cipher: []u8, spares: []Spare, stored: u16) -> bool {
	groups := make([dynamic]Variants, context.temp_allocator)
	combos := 1
	for end := len(spares); end > 0 && combos < 1 << 20; {
		at := spares[end - 1].at / 16 * 16
		start := end - 1
		for start > 0 && spares[start - 1].at / 16 * 16 == at {
			start -= 1
		}
		g := Variants{at, spares[start:end], nil}
		g.deltas = variant_deltas(a, plain, cipher, g.at, g.spares)
		combos *= len(g.deltas)
		append(&groups, g)
		end = start
	}

	pick := search_variants(groups[:], hash.crc32(cipher), stored) or_return
	for g, k in groups {
		apply_variant(plain[g.at:g.at + 16], g.at, g.spares, pick[k])
		aes.encrypt_ecb(&a.aes, cipher[g.at:g.at + 16], plain[g.at:g.at + 16])
	}
	return crc16(cipher) == stored
}

@(private = "file")
Variants :: struct {
	at:     int, // the AES block
	spares: []Spare,
	deltas: []u32, // CRC32 change per variant; variant 0 changes nothing
}

// Every combination of one variant per group, until one lands on `stored`.
@(private = "file")
search_variants :: proc(groups: []Variants, base: u32, stored: u16) -> (pick: []int, ok: bool) {
	pick = make([]int, len(groups), context.temp_allocator)
	for {
		c := base
		for g, k in groups {
			c ~= g.deltas[pick[k]]
		}
		if u16(c) + u16(c >> 16) == stored {
			return pick, true
		}
		k := 0
		for ; k < len(groups); k += 1 {
			pick[k] += 1
			if pick[k] < len(groups[k].deltas) {
				break
			}
			pick[k] = 0
		}
		if k == len(groups) {
			return
		}
	}
}

@(private = "file")
variant_deltas :: proc(a: ^Archive, plain, cipher: []u8, at: int, spares: []Spare) -> []u32 {
	MAX_VARIANTS :: 64
	n := min(1 << uint(min(len(spares), 16)), MAX_VARIANTS)
	deltas := make([]u32, n, context.temp_allocator)
	seed := hash.crc32(cipher[:at])
	tail := cipher[at + 16:]
	unchanged := hash.crc32(tail, hash.crc32(cipher[at:at + 16], seed))
	for v in 1 ..< n {
		block, enc: [16]u8
		copy(block[:], plain[at:at + 16])
		apply_variant(block[:], at, spares, v)
		aes.encrypt_ecb(&a.aes, enc[:], block[:])
		deltas[v] = hash.crc32(tail, hash.crc32(enc[:], seed)) ~ unchanged
	}
	return deltas
}

// Variant `v` swaps in the alt of spare i when bit i of v is set.
@(private = "file")
apply_variant :: proc(block: []u8, at: int, spares: []Spare, v: int) {
	for s, i in spares {
		if i < 16 && v & (1 << uint(i)) != 0 {
			block[s.at - at] = s.alt
		}
	}
}

@(private = "file")
find :: proc(a: ^Archive, name: string) -> (entry: Entry, ok: bool) {
	w := a.words
	entries, shared, names, blocks := int(w[7]), int(w[8]), int(w[9]), block_table(a)
	n_blocks := (int(w[11]) - blocks) / 8
	h := a.header

	for i in 0 ..< int(w[4]) {
		e := entries + 24 * i
		if endian.unchecked_get_u16le(h[e + 10:]) & 2 != 0 { // a directory
			continue
		}
		s := shared + 28 * int(endian.unchecked_get_u32le(h[e + 12:]))
		name_at := names + int(endian.unchecked_get_u32le(h[s + 12:]))
		if cstring_at(h, name_at) != name {
			continue
		}
		start := int(endian.unchecked_get_u64le(h[e:]))
		first := int(endian.unchecked_get_u32le(h[e + 16:]))
		size := int(endian.unchecked_get_u32le(h[s + 16:]))

		// A file's blocks run until the next file's first block.
		last := n_blocks
		for j in 0 ..< int(w[4]) {
			o := entries + 24 * j
			next := int(endian.unchecked_get_u32le(h[o + 16:]))
			if endian.unchecked_get_u16le(h[o + 10:]) & 2 == 0 && next > first && next < last {
				last = next
			}
		}
		list := make([]Block, last - first, context.temp_allocator)
		prev := 0
		for b in first ..< last {
			end := int(endian.unchecked_get_u32le(h[blocks + 8 * b:]))
			list[b - first] = {b, start + prev, start + end}
			prev = end
		}
		if len(list) == 0 || list[len(list) - 1].end > len(a.raw) || prev < size {
			return
		}
		return Entry{size, list}, true
	}
	return
}

@(private = "file")
block_table :: proc(a: ^Archive) -> int {
	return int(a.words[10])
}

@(private = "file")
decrypt_entry :: proc(a: ^Archive, entry: Entry, allocator := context.allocator) -> []u8 {
	last := entry.blocks[len(entry.blocks) - 1]
	plain := make([]u8, last.end - entry.blocks[0].start, allocator)
	at := 0
	for b in entry.blocks {
		ecb(&a.aes, plain[at:at + b.end - b.start], a.raw[b.start:b.end], decrypt = true)
		at += b.end - b.start
	}
	return plain
}

@(private = "file")
ecb :: proc(ctx: ^aes.Context_ECB, dst, src: []u8, decrypt := false) {
	for i := 0; i < len(src); i += 16 {
		if decrypt {
			aes.decrypt_ecb(ctx, dst[i:i + 16], src[i:i + 16])
		} else {
			aes.encrypt_ecb(ctx, dst[i:i + 16], src[i:i + 16])
		}
	}
}

@(private = "file")
cstring_at :: proc(data: []u8, at: int) -> string {
	end := at
	for end < len(data) && data[end] != 0 {
		end += 1
	}
	return string(data[at:end])
}

// Raw RSA, e = 65537, no padding, little-endian both ways.
@(private = "file")
rsa_intro :: proc(signed: []u8, words: ^[32]u32) -> bool {
	m, e, n, out := &big.Int{}, &big.Int{}, &big.Int{}, &big.Int{}
	defer big.destroy(m, e, n, out)
	key := DIRT3_KEY
	if big.int_from_bytes_little(m, signed) != nil ||
	   big.int_from_bytes_little(n, key[:]) != nil ||
	   big.set(e, 65537) != nil ||
	   big.internal_int_exponent_mod(out, m, e, n) != nil {
		return false
	}
	buf: [128]u8
	if big.int_to_bytes_little(out, buf[:]) != nil {
		return false
	}
	for &word, i in words {
		word = endian.unchecked_get_u32le(buf[4 * i:])
	}
	return true
}

// dirt3_game.exe 0x78f800.
@(private = "file")
unscramble :: proc(w: ^[32]u32) {
	w[14] ~= w[5]; w[5] ~= w[2]; w[2] ~= w[4]; w[4] ~= w[7]; w[7] ~= w[3]
	w[3] ~= w[9]; w[9] ~= w[10]; w[10] ~= w[1]; w[1] ~= w[13]; w[13] ~= w[11]
	w[11] ~= w[0]; w[0] ~= w[12]; w[12] ~= w[6]; w[6] ~= w[8]; w[8] ~= w[14]
	for i in 15 ..< 31 {
		w[i] ~= w[14]
	}
}
