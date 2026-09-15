package d3

// EGO LNG extension string tables. All integers are big-endian. Encoding
// rebuilds the buckets, so verification is semantic rather than byte-exact.

import "base:runtime"
import "core:fmt"
import "core:strings"

Lng_Entry :: struct {
	key:   string,
	value: string,
}

Lng :: struct {
	magic:       [4]u8,
	hshs_magic:  [4]u8,
	hsht_magic:  [4]u8,
	sida_magic:  [4]u8,
	sidb_magic:  [4]u8,
	lngb_magic:  [4]u8,
	seed:        u32,
	multiplier:  u32,
	bucket_count: int,
	entries:     [dynamic]Lng_Entry,
}

@(private = "file")
Lng_Span :: struct {
	start: int,
	count: int,
}

@(private = "file")
lng_u32 :: proc(data: []u8, at: int) -> u32 {
	return binary_load_u32(data, at, .Big)
}

@(private = "file")
lng_put_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	append(out, u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value))
}

@(private = "file")
lng_magic_at :: proc(data: []u8, at: int) -> [4]u8 {
	return {data[at], data[at + 1], data[at + 2], data[at + 3]}
}

@(private = "file")
lng_put_magic :: proc(out: ^[dynamic]u8, magic: [4]u8) {
	append(out, magic[0], magic[1], magic[2], magic[3])
}

@(private = "file")
lng_zstring :: proc(
	data: []u8,
	at: int,
	allocator: runtime.Allocator,
) -> (
	value: string,
	ok: bool,
) {
	if at < 0 || at >= len(data) {
		return "", false
	}
	end := at
	for end < len(data) && data[end] != 0 {
		end += 1
	}
	if end == len(data) {
		return "", false
	}
	return strings.clone(string(data[at:end]), allocator), true
}

@(private = "file")
lng_read_header :: proc(data: []u8, lng: ^Lng, at: ^int) -> (string, bool) {
	if len(data) < 8 || int(lng_u32(data, 4)) != len(data) {
		return "LNG size header disagrees with file", false
	}
	lng.magic = lng_magic_at(data, 0)
	at^ = 8
	return "", true
}

@(private = "file")
lng_read_hash_settings :: proc(data: []u8, lng: ^Lng, at: ^int) -> (string, bool) {
	if at^ + 20 > len(data) {
		return "LNG ends in HSHS", false
	}
	lng.hshs_magic = lng_magic_at(data, at^)
	if lng_u32(data, at^ + 4) != 12 {
		return "unexpected HSHS size", false
	}
	lng.bucket_count = int(lng_u32(data, at^ + 8))
	lng.seed = lng_u32(data, at^ + 12)
	lng.multiplier = lng_u32(data, at^ + 16)
	at^ += 20
	if lng.bucket_count <= 0 {
		return "invalid LNG bucket count", false
	}
	return "", true
}

@(private = "file")
lng_read_spans :: proc(data: []u8, lng: ^Lng, at: ^int) -> ([]Lng_Span, string, bool) {
	if at^ + 8 > len(data) {
		return nil, "LNG ends in HSHT", false
	}
	lng.hsht_magic = lng_magic_at(data, at^)
	size := int(lng_u32(data, at^ + 4))
	if size != lng.bucket_count * 8 || at^ + 8 + size > len(data) {
		return nil, "unexpected HSHT size", false
	}
	spans := make([]Lng_Span, lng.bucket_count, context.temp_allocator)
	for i in 0 ..< lng.bucket_count {
		spans[i] = {
			start = int(lng_u32(data, at^ + 8 + i * 8)),
			count = int(lng_u32(data, at^ + 12 + i * 8)),
		}
	}
	at^ += 8 + size
	return spans, "", true
}

@(private = "file")
lng_read_offsets :: proc(data: []u8, lng: ^Lng, at: ^int) -> ([][2]int, string, bool) {
	if at^ + 12 > len(data) {
		return nil, "LNG ends in SIDA", false
	}
	lng.sida_magic = lng_magic_at(data, at^)
	size := int(lng_u32(data, at^ + 4))
	count := int(lng_u32(data, at^ + 8))
	if size != count * 8 || at^ + 12 + size > len(data) {
		return nil, "unexpected SIDA size", false
	}
	offsets := make([][2]int, count, context.temp_allocator)
	for i in 0 ..< count {
		offsets[i] = {
			int(lng_u32(data, at^ + 12 + i * 8)),
			int(lng_u32(data, at^ + 16 + i * 8)),
		}
	}
	at^ += 12 + size
	return offsets, "", true
}

@(private = "file")
lng_read_buffer :: proc(data: []u8, at: ^int, final: bool) -> ([4]u8, []u8, string, bool) {
	if at^ + 8 > len(data) {
		return {}, nil, "LNG ends in string buffer", false
	}
	magic := lng_magic_at(data, at^)
	size := int(lng_u32(data, at^ + 4))
	end := at^ + 8 + size
	if end > len(data) || (final && end != len(data)) {
		return {}, nil, "trailing or truncated LNG string buffer", false
	}
	buffer := data[at^ + 8:end]
	at^ = end
	return magic, buffer, "", true
}

@(private = "file")
lng_validate_spans :: proc(spans: []Lng_Span, count: int) -> (string, bool) {
	next := 0
	for span in spans {
		if span.count < 0 || span.start != (span.count > 0 ? next : 0) {
			return "LNG bucket spans are not contiguous", false
		}
		next += span.count
		if next > count {
			return "LNG bucket span exceeds the entry table", false
		}
	}
	if next != count {
		return "LNG buckets do not cover every entry", false
	}
	return "", true
}

@(private = "file")
lng_read_entries :: proc(
	offsets: [][2]int,
	spans: []Lng_Span,
	keys, values: []u8,
	allocator: runtime.Allocator,
) -> ([dynamic]Lng_Entry, string, bool) {
	flat := make([]Lng_Entry, len(offsets), context.temp_allocator)
	owned := 0
	succeeded := false
	defer if !succeeded {
		for entry in flat[:owned] {
			delete(entry.key, allocator)
			delete(entry.value, allocator)
		}
	}
	for pair, i in offsets {
		key, key_ok := lng_zstring(keys, pair[0], allocator)
		if !key_ok {
			return nil, "bad LNG key offset", false
		}
		value, value_ok := lng_zstring(values, pair[1], allocator)
		if !value_ok {
			delete(key, allocator)
			return nil, "bad LNG value offset", false
		}
		flat[i] = {key = key, value = value}
		owned += 1
	}
	entries := make([dynamic]Lng_Entry, 0, len(offsets), allocator)
	for span in spans {
		for entry in flat[span.start:span.start + span.count] {
			append(&entries, entry)
		}
	}
	succeeded = true
	return entries, "", true
}

lng_load :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	lng: Lng,
	msg: string,
	ok: bool,
) {
	defer if !ok {
		lng_delete(&lng, allocator)
	}

	at := 0
	if msg, ok = lng_read_header(data, &lng, &at); !ok { return }
	if msg, ok = lng_read_hash_settings(data, &lng, &at); !ok { return }
	spans, span_msg, spans_ok := lng_read_spans(data, &lng, &at)
	if !spans_ok { return lng, span_msg, false }
	offsets, offset_msg, offsets_ok := lng_read_offsets(data, &lng, &at)
	if !offsets_ok { return lng, offset_msg, false }
	if msg, ok = lng_validate_spans(spans, len(offsets)); !ok { return }
	keys: []u8
	lng.sidb_magic, keys, msg, ok = lng_read_buffer(data, &at, false)
	if !ok { return lng, msg, false }
	values: []u8
	lng.lngb_magic, values, msg, ok = lng_read_buffer(data, &at, true)
	if !ok { return lng, msg, false }
	lng.entries, msg, ok = lng_read_entries(offsets, spans, keys, values, allocator)
	if !ok { return }
	return lng, "", true
}

lng_delete :: proc(lng: ^Lng, allocator := context.allocator) {
	for entry in lng.entries {
		delete(entry.key, allocator)
		delete(entry.value, allocator)
	}
	delete(lng.entries)
	lng^ = {}
}

lng_set :: proc(lng: ^Lng, key, value: string, allocator := context.allocator) {
	for &entry in lng.entries {
		if entry.key != key {
			continue
		}
		delete(entry.value, allocator)
		entry.value = strings.clone(value, allocator)
		return
	}
	append(
		&lng.entries,
		Lng_Entry {
			key = strings.clone(key, allocator),
			value = strings.clone(value, allocator),
		},
	)
}

@(private = "file")
lng_hash :: proc(lng: Lng, key: string, bucket_count: int) -> int {
	value := lng.seed
	for character in key {
		value = value * lng.multiplier + u32(character)
	}
	return int(value % u32(bucket_count))
}

lng_encode :: proc(lng: Lng, allocator := context.allocator) -> []u8 {
	bucket_count := len(lng.entries) / 2 + 1
	buckets := make([][dynamic]int, bucket_count, context.temp_allocator)
	defer {
		for &bucket in buckets {
			delete(bucket)
		}
		delete(buckets, context.temp_allocator)
	}
	for entry, i in lng.entries {
		bucket := lng_hash(lng, entry.key, bucket_count)
		append(&buckets[bucket], i)
	}

	keys := make([dynamic]u8, context.temp_allocator)
	values := make([dynamic]u8, context.temp_allocator)
	offsets := make([][2]u32, len(lng.entries), context.temp_allocator)
	for bucket in buckets {
		for i in bucket {
			entry := lng.entries[i]
			offsets[i] = {u32(len(keys)), u32(len(values))}
			append(&keys, entry.key)
			append(&keys, 0)
			append(&values, entry.value)
			append(&values, 0)
		}
	}

	// SIDA order must match flattened bucket order, not original entry order.
	ordered := make([dynamic]int, context.temp_allocator)
	for bucket in buckets {
		append(&ordered, ..bucket[:])
	}

	out := make([dynamic]u8, allocator)
	lng_put_magic(&out, lng.magic)
	lng_put_u32(&out, 0) // patched with total size below
	lng_put_magic(&out, lng.hshs_magic)
	lng_put_u32(&out, 12)
	lng_put_u32(&out, u32(bucket_count))
	lng_put_u32(&out, lng.seed)
	lng_put_u32(&out, lng.multiplier)

	lng_put_magic(&out, lng.hsht_magic)
	lng_put_u32(&out, u32(bucket_count * 8))
	start := 0
	for bucket in buckets {
		lng_put_u32(&out, len(bucket) > 0 ? u32(start) : 0)
		lng_put_u32(&out, u32(len(bucket)))
		start += len(bucket)
	}

	lng_put_magic(&out, lng.sida_magic)
	lng_put_u32(&out, u32(len(ordered) * 8))
	lng_put_u32(&out, u32(len(ordered)))
	for i in ordered {
		lng_put_u32(&out, offsets[i][0])
		lng_put_u32(&out, offsets[i][1])
	}

	lng_put_magic(&out, lng.sidb_magic)
	lng_put_u32(&out, u32(len(keys)))
	append(&out, ..keys[:])
	lng_put_magic(&out, lng.lngb_magic)
	lng_put_u32(&out, u32(len(values)))
	append(&out, ..values[:])

	size := u32(len(out))
	out[4] = u8(size >> 24)
	out[5] = u8(size >> 16)
	out[6] = u8(size >> 8)
	out[7] = u8(size)
	return out[:]
}

lng_equal :: proc(a, b: Lng) -> bool {
	if len(a.entries) != len(b.entries) {
		return false
	}
	for expected in a.entries {
		found := false
		for actual in b.entries {
			if expected.key == actual.key && expected.value == actual.value {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

verified_lng_bytes :: proc(
	raw: []u8,
	key, value: string,
	allocator := context.allocator,
) -> (
	data: []u8,
	msg: string,
	ok: bool,
) {
	lng, load_msg, loaded := lng_load(raw, context.temp_allocator)
	if !loaded {
		return nil, load_msg, false
	}
	lng_set(&lng, key, value, context.temp_allocator)
	data = lng_encode(lng, allocator)

	again, verify_msg, verified := lng_load(data, context.temp_allocator)
	if !verified {
		delete(data, allocator)
		return nil, verify_msg, false
	}
	if !lng_equal(lng, again) {
		delete(data, allocator)
		return nil, "semantic verification failed while rebuilding LNG", false
	}
	return data, "", true
}
