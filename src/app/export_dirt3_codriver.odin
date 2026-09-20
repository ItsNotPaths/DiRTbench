package main

import "core:strings"
import "../d3"
import "../geo"

// The co-driver's vocabulary, one file per base venue, baked for the same
// reason the palettes and the preview clips are: a release is one file to copy,
// and a half-installed vocabulary would put a wrong call on a corner rather
// than fail.
//
// A venue with no file here simply says nothing. We cannot write speech, so a
// bank nobody has transcribed has no calls to give. See docs/guide-pacenotes.md.
CODRIVER_VOCAB := #load_directory("../../assets/d3/codriver")

CODRIVER_EXT :: ".txt"

// `finland/finland_rally` -> `finland_finland_rally.txt`, as with palettes.
codriver_vocab_name :: proc(base: string, allocator := context.temp_allocator) -> string {
	flat, _ := strings.replace_all(base, "/", "_", allocator)
	return strings.concatenate({flat, CODRIVER_EXT}, allocator)
}

codriver_vocabulary :: proc(base: string) -> []u8 {
	if base == "" {
		return nil
	}
	want := codriver_vocab_name(base)
	for file in CODRIVER_VOCAB {
		if file.name == want {
			return file.data
		}
	}
	return nil
}

// Our notes as the exporter's calls.
//
// `station` rather than `at`: the note's own firing point is where the box
// goes. Stock late boxes sit a median 48 m before the corner apex and ours is
// generated the same way, so the two agree without a second lead.
//
// A `Hectic` note becomes `care`, which is the nearest thing any bank actually
// says. The generator's own word for it is a placeholder with no recording
// anywhere.
d3_codriver_calls :: proc(
	notes: []geo.Pace_Note,
	allocator := context.temp_allocator,
) -> []d3.D3_Call {
	out := make([dynamic]d3.D3_Call, allocator)
	for note in notes {
		call := d3.D3_Call{at = note.station, severity = d3.D3_NO_SEVERITY}
		switch note.link {
		case .None:
		case .Into:
			call.link = .Into
		case .And:
			call.link = .And
		}
		switch note.kind {
		case .Corner:
			call.side = note.dir == .Right ? .Right : .Left
			// `square` has no severity of its own in any bank we have read, so
			// it takes the severity its radius already put it in.
			call.severity = note.sev
			if .Long in note.mods {call.mods += {.Long}}
			if .Tightens in note.mods {call.mods += {.Tightens}}
			if .Opens in note.mods {call.mods += {.Opens}}
		case .Distance:
			call.distance = note.dist
		case .Crest:
			call.features += {.Crest}
		case .Dip:
			call.features += {.Dip}
		case .Jump:
			call.features += {.Jump}
		case .Hectic:
			call.features += {.Care}
		}
		append(&out, call)
	}
	return out[:]
}
