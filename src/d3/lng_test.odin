package d3

import "core:testing"

@(private = "file")
set_be_u32 :: proc(data: []u8, at: int, value: u32) {
	data[at] = u8(value >> 24)
	data[at + 1] = u8(value >> 16)
	data[at + 2] = u8(value >> 8)
	data[at + 3] = u8(value)
}

@(private = "file")
test_lng :: proc() -> Lng {
	entries := make([dynamic]Lng_Entry)
	append(
		&entries,
		Lng_Entry{key = "db_alpha", value = "ALPHA"},
		Lng_Entry{key = "db_beta", value = "BETA"},
	)
	return Lng {
		magic        = {'L', 'N', 'G', 0},
		hshs_magic   = {'H', 'S', 'H', 'S'},
		hsht_magic   = {'H', 'S', 'H', 'T'},
		sida_magic   = {'S', 'I', 'D', 'A'},
		sidb_magic   = {'S', 'I', 'D', 'B'},
		lngb_magic   = {'L', 'N', 'G', 'B'},
		seed         = 7,
		multiplier   = 31,
		bucket_count = 2,
		entries      = entries,
	}
}

@(test)
lng_encode_reparse_preserves_the_map :: proc(t: ^testing.T) {
	lng := test_lng()
	defer delete(lng.entries)
	data := lng_encode(lng)
	defer delete(data)
	again, msg, ok := lng_load(data)
	defer lng_delete(&again)

	testing.expectf(t, ok, "encoded LNG did not parse: %s", msg)
	testing.expect(t, lng_equal(lng, again))
}

@(test)
verified_lng_adds_one_key_without_losing_existing_strings :: proc(t: ^testing.T) {
	lng := test_lng()
	defer delete(lng.entries)
	raw := lng_encode(lng)
	defer delete(raw)
	data, msg, ok := verified_lng_bytes(raw, "db_gamma", "GAMMA")
	defer delete(data)
	testing.expectf(t, ok, "verification failed: %s", msg)

	again, parse_msg, parsed := lng_load(data)
	defer lng_delete(&again)
	testing.expectf(t, parsed, "result did not parse: %s", parse_msg)
	testing.expect_value(t, len(again.entries), 3)

	found := 0
	for entry in again.entries {
		if entry.key == "db_alpha" && entry.value == "ALPHA" {
			found += 1
		}
		if entry.key == "db_beta" && entry.value == "BETA" {
			found += 1
		}
		if entry.key == "db_gamma" && entry.value == "GAMMA" {
			found += 1
		}
	}
	testing.expect_value(t, found, 3)
}

@(test)
lng_rejects_a_non_contiguous_bucket_table :: proc(t: ^testing.T) {
	lng := test_lng()
	defer delete(lng.entries)
	data := lng_encode(lng)
	defer delete(data)

	// HSHT starts at 28; its first bucket span starts at 36.
	set_be_u32(data, 36, 1)
	_, _, ok := lng_load(data)
	testing.expect(t, !ok)
}

@(test)
lng_rejects_a_string_offset_outside_its_buffer :: proc(t: ^testing.T) {
	lng := test_lng()
	defer delete(lng.entries)
	data := lng_encode(lng)
	defer delete(data)

	// Two buckets put SIDA at 52; its first value offset is at 68.
	set_be_u32(data, 68, 0xffff_ffff)
	_, _, ok := lng_load(data)
	testing.expect(t, !ok)
}
