package d3

import "core:fmt"
import "core:strconv"
import "core:strings"

// `objects.ens`: the per-route physics/cloth placement file — rigid-body
// props (hay bales, fences, tyre stacks), the collidable subset of static
// trees/ornaments, and cloth (pole mesh/tape), traced
// in Ghidra to a real runtime load inside physics setup, not the renderer.
// Unlike `trees.bin`/`ornaments.bin` this is plain text, not BinXML: CRLF
// line endings, no trailing newline, a fixed header and footer, and a flat
// list of records in between. A hand-built parser/emitter round-trips a real
// stock file byte-for-byte, which is what `d3_ens_parse`/`d3_ens_emit` below
// do — see `docs/dirt3-odin-roadmap.md` and `docs/roadmap-venues.md` for the
// byte-level evidence and the live-drive confirmations. Static scenery is
// deliberately duplicated: trees.bin/ornaments.bin place its render copy,
// while a matching ENS instance places its objecttypes.pssg rigid body. See
// docs/dirt3-static-object-collision.md.
//
// Five record shapes appear, and every one fits one of three generic shapes
// rather than needing its own struct: self-closing (`TEMPLATEENTITYREFERENCE`,
// `TEMPLATECLOTHTYPEPOOL`, `TEMPLATECLOTHATTACHINSTANCE`), a single inline
// text child (`TEMPLATETRANSFORM`), or nested children
// (`TEMPLATEENTITYINSTANCE`, `TEMPLATEBASICENTITYINSTANCE`,
// `TEMPLATECLOTHINSTANCE`). `Ens_Node` models exactly those three shapes and
// nothing more specific, so a new tag the game ships tomorrow parses for
// free.

Ens_Attr :: struct {
	name:  string,
	value: string,
}

Ens_Content :: enum {
	Self_Close, // <TAG attr="v" ... />
	Text,       // <TAG>text</TAG>, no attrs, one line
	Children,   // <TAG attr="v" ...>\r\n  ...children...\r\n</TAG>
}

Ens_Node :: struct {
	tag:      string,
	attrs:    []Ens_Attr,
	content:  Ens_Content,
	text:     string,     // set only when content == .Text
	children: []Ens_Node, // set only when content == .Children
}

ENS_HEADER :: "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\r\n" +
	"<PSSGFILE version=\"0.4.0.0beta\">\r\n" +
	"\t<PSSGDATABASE creator=\"CSSGXml\">\r\n"
ENS_FOOTER :: "\t</PSSGDATABASE>\r\n</PSSGFILE>"

ens_attr :: proc(node: Ens_Node, name: string) -> (value: string, ok: bool) {
	for a in node.attrs {
		if a.name == name { return a.value, true }
	}
	return "", false
}

// Real per-tag `track.vis` ids for a route's `staticVis="1"` entities, read
// straight off the file's own `instanceID` attribute. Confirmed exact against
// every stock route's own `track.vis` tag-2 section, game-wide, across every
// venue sampled — see docs/dirt3-vis-format.md, "The ornaments crash".
d3_ens_static_vis_ids :: proc(nodes: []Ens_Node, allocator := context.allocator) -> (ids: []u32, ok: bool) {
	out := make([dynamic]u32, allocator)
	for node in nodes {
		if node.tag != "TEMPLATEENTITYINSTANCE" { continue }
		vis, has_vis := ens_attr(node, "staticVis")
		if !has_vis || vis != "1" { continue }
		id_str, has_id := ens_attr(node, "instanceID")
		if !has_id { delete(out); return nil, false }
		id, id_ok := strconv.parse_int(id_str)
		if !id_ok { delete(out); return nil, false }
		append(&out, u32(id))
	}
	return out[:], true
}

// --- parse -------------------------------------------------------------

@(private = "file")
Ens_Scan :: struct {
	text: string,
	pos:  int,
}

@(private = "file")
ens_eat :: proc(s: ^Ens_Scan, literal: string) -> bool {
	if !strings.has_prefix(s.text[s.pos:], literal) { return false }
	s.pos += len(literal)
	return true
}

@(private = "file")
ens_is_ident_byte :: proc(c: u8) -> bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
ens_read_ident :: proc(s: ^Ens_Scan) -> (ident: string, ok: bool) {
	start := s.pos
	for s.pos < len(s.text) && ens_is_ident_byte(s.text[s.pos]) { s.pos += 1 }
	if s.pos == start { return "", false }
	return s.text[start:s.pos], true
}

// Zero or more `\tname="value"` runs, stopping (without consuming) at the
// tag's closing `/>` or `>`.
@(private = "file")
ens_read_attrs :: proc(s: ^Ens_Scan, allocator := context.allocator) -> (attrs: []Ens_Attr, ok: bool) {
	out := make([dynamic]Ens_Attr, allocator)
	for s.pos < len(s.text) && s.text[s.pos] == ' ' {
		save := s.pos
		s.pos += 1
		name, name_ok := ens_read_ident(s)
		if !name_ok || !ens_eat(s, "=\"") {
			s.pos = save
			break
		}
		vend := strings.index_byte(s.text[s.pos:], '"')
		if vend < 0 { return nil, false }
		value := s.text[s.pos : s.pos+vend]
		s.pos += vend + 1
		append(&out, Ens_Attr{name, value})
	}
	return out[:], true
}

@(private = "file")
ens_parse_node :: proc(s: ^Ens_Scan, allocator := context.allocator) -> (node: Ens_Node, ok: bool) {
	for s.pos < len(s.text) && s.text[s.pos] == '\t' { s.pos += 1 }
	if !ens_eat(s, "<") { return {}, false }
	tag, tag_ok := ens_read_ident(s)
	if !tag_ok { return {}, false }
	attrs, attrs_ok := ens_read_attrs(s, allocator)
	if !attrs_ok { return {}, false }

	if ens_eat(s, " />\r\n") {
		return Ens_Node{tag = tag, attrs = attrs, content = .Self_Close}, true
	}
	if !ens_eat(s, ">") { return {}, false }

	if ens_eat(s, "\r\n") {
		children, children_ok := ens_parse_children(s, tag, allocator)
		if !children_ok { return {}, false }
		return Ens_Node{tag = tag, attrs = attrs, content = .Children, children = children}, true
	}

	close_tag := strings.concatenate({"</", tag, ">\r\n"}, allocator)
	end := strings.index(s.text[s.pos:], close_tag)
	if end < 0 { return {}, false }
	text := s.text[s.pos : s.pos+end]
	s.pos += end + len(close_tag)
	return Ens_Node{tag = tag, attrs = attrs, content = .Text, text = text}, true
}

// Sibling nodes up to (and including consuming) `</parent_tag>\r\n`, whatever
// depth of leading tabs it sits at.
@(private = "file")
ens_parse_children :: proc(s: ^Ens_Scan, parent_tag: string, allocator := context.allocator) -> (children: []Ens_Node, ok: bool) {
	out := make([dynamic]Ens_Node, allocator)
	close_tag := strings.concatenate({"</", parent_tag, ">\r\n"}, allocator)
	for {
		save := s.pos
		for s.pos < len(s.text) && s.text[s.pos] == '\t' { s.pos += 1 }
		if strings.has_prefix(s.text[s.pos:], close_tag) {
			s.pos += len(close_tag)
			return out[:], true
		}
		s.pos = save
		child, child_ok := ens_parse_node(s, allocator)
		if !child_ok { return nil, false }
		append(&out, child)
	}
}

// Parse a whole `objects.ens` file. Fails closed on anything that does not
// match the header/footer template exactly, or a record shape not covered by
// `Ens_Content` — never guesses.
d3_ens_parse :: proc(data: []u8, allocator := context.allocator) -> (nodes: []Ens_Node, ok: bool) {
	text := string(data)
	if !strings.has_prefix(text, ENS_HEADER) || !strings.has_suffix(text, ENS_FOOTER) {
		return nil, false
	}
	body := text[len(ENS_HEADER) : len(text)-len(ENS_FOOTER)]
	s := Ens_Scan{text = body}
	out := make([dynamic]Ens_Node, allocator)
	for s.pos < len(s.text) {
		node, node_ok := ens_parse_node(&s, allocator)
		if !node_ok { return nil, false }
		append(&out, node)
	}
	return out[:], true
}

// --- emit ----------------------------------------------------------------

@(private = "file")
ens_write_attrs :: proc(b: ^strings.Builder, attrs: []Ens_Attr) {
	for a in attrs {
		strings.write_string(b, " ")
		strings.write_string(b, a.name)
		strings.write_string(b, "=\"")
		strings.write_string(b, a.value)
		strings.write_string(b, "\"")
	}
}

@(private = "file")
ens_write_node :: proc(b: ^strings.Builder, node: Ens_Node, depth: int) {
	for _ in 0 ..< depth { strings.write_string(b, "\t") }
	switch node.content {
	case .Self_Close:
		strings.write_string(b, "<")
		strings.write_string(b, node.tag)
		ens_write_attrs(b, node.attrs)
		strings.write_string(b, " />\r\n")
	case .Text:
		strings.write_string(b, "<")
		strings.write_string(b, node.tag)
		strings.write_string(b, ">")
		strings.write_string(b, node.text)
		strings.write_string(b, "</")
		strings.write_string(b, node.tag)
		strings.write_string(b, ">\r\n")
	case .Children:
		strings.write_string(b, "<")
		strings.write_string(b, node.tag)
		ens_write_attrs(b, node.attrs)
		strings.write_string(b, ">\r\n")
		for child in node.children { ens_write_node(b, child, depth+1) }
		for _ in 0 ..< depth { strings.write_string(b, "\t") }
		strings.write_string(b, "</")
		strings.write_string(b, node.tag)
		strings.write_string(b, ">\r\n")
	}
}

// Reassemble a full `objects.ens` from a node list. Every record sits two
// tabs deep, directly under `<PSSGDATABASE>`, matching every stock file
// sampled.
d3_ens_emit :: proc(nodes: []Ens_Node, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(allocator)
	strings.write_string(&b, ENS_HEADER)
	for node in nodes { ens_write_node(&b, node, 2) }
	strings.write_string(&b, ENS_FOOTER)
	return b.buf[:]
}

// One object type's visual placements and corresponding rigid bodies.
D3_Ens_Static_Set :: struct {
	ens_reference_id:      string,
	entity_uri:            string,
	instance_id_prefix:    string,
	placement_reference_id: u32,
	instances:             []D3_Placement_Instance,
}

ens_owned_attrs :: proc(pairs: ..Ens_Attr, allocator := context.allocator) -> []Ens_Attr {
	out := make([]Ens_Attr, len(pairs), allocator)
	for pair, i in pairs {
		out[i] = {
			name  = strings.clone(pair.name, allocator),
			value = strings.clone(pair.value, allocator),
		}
	}
	return out
}

ens_owned_child :: proc(child: Ens_Node, allocator := context.allocator) -> []Ens_Node {
	out := make([]Ens_Node, 1, allocator)
	out[0] = child
	return out
}

// objecttypes.pssg's shape-local transform is composed later by the engine.
d3_ens_placement_transform :: proc(instance: D3_Placement_Instance, allocator := context.allocator) -> Ens_Node {
	text := fmt.tprintf(
		"%.9g %.9g %.9g 0 %.9g %.9g %.9g 0 %.9g %.9g %.9g 0 %.9g %.9g %.9g 1 ",
		instance.basis[0][0], instance.basis[0][1], instance.basis[0][2],
		instance.basis[1][0], instance.basis[1][1], instance.basis[1][2],
		instance.basis[2][0], instance.basis[2][1], instance.basis[2][2],
		instance.position[0], instance.position[1], instance.position[2],
	)
	return {
		tag     = "TEMPLATETRANSFORM",
		content = .Text,
		text    = strings.clone(text, allocator),
	}
}

// Emit BASIC physics entities from the exact slice used by the visual writer.
d3_ens_static_set_nodes :: proc(
	set: D3_Ens_Static_Set,
	allocator := context.allocator,
) -> (
	nodes: []Ens_Node,
	msg: string,
	ok: bool,
) {
	if set.ens_reference_id == "" { return nil, "ENS static set needs a reference id", false }
	if set.entity_uri == "" { return nil, "ENS static set needs an objecttypes entity URI", false }
	if set.instance_id_prefix == "" { return nil, "ENS static set needs an instance id prefix", false }
	if len(set.instances) == 0 { return []Ens_Node{}, "0 static physics instances", true }
	for instance, i in set.instances {
		if instance.reference_id != set.placement_reference_id {
			return nil, fmt.tprintf(
				"ENS static set instance %d uses visual reference %d, expected %d",
				i, instance.reference_id, set.placement_reference_id,
			), false
		}
	}

	out := make([]Ens_Node, 1+len(set.instances), allocator)
	out[0] = {
		tag = "TEMPLATEENTITYREFERENCE",
		attrs = ens_owned_attrs(
			{"id", set.ens_reference_id}, {"uri", set.entity_uri}, {"allocAlt", "5"},
			allocator = allocator,
		),
		content = .Self_Close,
	}
	for instance, i in set.instances {
		id := fmt.tprintf("%s_%d", set.instance_id_prefix, i)
		tag := fmt.tprintf("%d", i+1)
		out[1+i] = {
			tag = "TEMPLATEBASICENTITYINSTANCE",
			attrs = ens_owned_attrs(
				{"id", id}, {"uri", fmt.tprintf("#%s", set.ens_reference_id)}, {"instance_tag", tag},
				allocator = allocator,
			),
			content  = .Children,
			children = ens_owned_child(d3_ens_placement_transform(instance, allocator), allocator),
		}
	}
	return out, fmt.tprintf("%d static physics instances of %s", len(set.instances), set.entity_uri), true
}
