package d3

// Node construction for a synthesized PSSG scene.
//
// An attribute name does not have one id. `id` is one number on a RENDERNODE
// and another on a DATABLOCK, and a reader resolves id to name, so a wrong id
// round-trips cleanly while the game reads nothing. Every id here is read off a
// real node of the same type in the donor.

import "core:fmt"
import "core:strings"

Pssg_Attr_Key :: struct {
	node: string,
	attr: string,
}

Pssg_Types :: struct {
	node_id: map[string]u32,
	attr_id: map[Pssg_Attr_Key]u32,
}

pssg_types_scan :: proc(file: ^Pssg_File, node: ^Pssg_Node, t: ^Pssg_Types) {
	t.node_id[node.name] = node.type_id
	for attr in node.attrs {
		name, known := file.attr_names[attr.type_id]
		if !known { continue }
		key := Pssg_Attr_Key{node=node.name, attr=name}
		if _, seen := t.attr_id[key]; !seen { t.attr_id[key] = attr.type_id }
	}
	for child in node.children { pssg_types_scan(file, child, t) }
}

pssg_types :: proc(file: ^Pssg_File, allocator := context.allocator) -> Pssg_Types {
	t := Pssg_Types{
		node_id = make(map[string]u32, allocator),
		attr_id = make(map[Pssg_Attr_Key]u32, allocator),
	}
	pssg_types_scan(file, file.root, &t)
	return t
}

// Short unique ids in the stock `!xx` style.
PSSG_ID_ALPHABET :: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

Pssg_Ids :: struct {
	taken: map[string]bool,
	next:  int,
}

pssg_ids_scan :: proc(file: ^Pssg_File, node: ^Pssg_Node, ids: ^Pssg_Ids) {
	if id := pssg_attr_string(file, node, "id"); id != "" { ids.taken[id] = true }
	for child in node.children { pssg_ids_scan(file, child, ids) }
}

pssg_ids :: proc(file: ^Pssg_File, allocator := context.allocator) -> Pssg_Ids {
	ids := Pssg_Ids{taken = make(map[string]bool, allocator)}
	pssg_ids_scan(file, file.root, &ids)
	return ids
}

pssg_ids_delete :: proc(ids: ^Pssg_Ids) { delete(ids.taken); ids^ = {} }

pssg_mint :: proc(ids: ^Pssg_Ids, allocator := context.allocator) -> string {
	alphabet := PSSG_ID_ALPHABET
	buf: [16]u8
	for {
		value := ids.next; ids.next += 1
		end := len(buf)
		for {
			end -= 1
			buf[end] = alphabet[value % len(alphabet)]
			value /= len(alphabet)
			if value == 0 { break }
		}
		candidate := strings.concatenate({"!", string(buf[end:])}, allocator)
		if candidate not_in ids.taken { ids.taken[candidate] = true; return candidate }
		delete(candidate, allocator)
	}
}

Pssg_Value :: union {
	u32,
	string,
}

Pssg_Set :: struct {
	name:  string,
	value: Pssg_Value,
}

// Build a node from attribute names. `data` and `children` are adopted, so a
// failure here frees them rather than leaking a half-built subtree.
pssg_make :: proc(
	types: ^Pssg_Types,
	name: string,
	attrs: []Pssg_Set,
	children: []^Pssg_Node = nil,
	data: []u8 = nil,
	allocator := context.allocator,
) -> (node: ^Pssg_Node, msg: string, ok: bool) {
	type_id, known := types.node_id[name]
	if !known {
		for child in children { pssg_node_delete(child, allocator) }
		if data != nil { delete(data, allocator) }
		return nil, fmt.tprintf("the Dirt 3 material pack has no %s node, so its type id is unknown", name), false
	}
	node = new(Pssg_Node, allocator)
	node.type_id = type_id
	node.name = name
	node.attrs = make([dynamic]Pssg_Attr, allocator)
	node.children = make([dynamic]^Pssg_Node, allocator)
	node.data = data
	node.data_owned = data != nil
	for child in children { append(&node.children, child) }
	for set in attrs {
		attr_id, attr_known := types.attr_id[Pssg_Attr_Key{node=name, attr=set.name}]
		if !attr_known {
			pssg_node_delete(node, allocator)
			return nil, fmt.tprintf("the Dirt 3 material pack has no %s node carrying %s, so its attribute id is unknown", name, set.name), false
		}
		value: []u8
		switch v in set.value {
		case u32:
			value = make([]u8, 4, allocator)
			binary_store_u32(value, 0, v, .Big)
		case string:
			value = make([]u8, 4+len(v), allocator)
			binary_store_u32(value, 0, u32(len(v)), .Big)
			copy(value[4:], transmute([]u8)v)
		}
		append(&node.attrs, Pssg_Attr{type_id=attr_id, value=value, owned=true})
	}
	return node, "", true
}

pssg_set_children :: proc(node: ^Pssg_Node, children: []^Pssg_Node, allocator := context.allocator) {
	for child in node.children { pssg_node_delete(child, allocator) }
	clear(&node.children)
	for child in children { append(&node.children, child) }
}

pssg_box_bytes :: proc(lo, hi: [3]f32, allocator := context.allocator) -> []u8 {
	out := make([]u8, 24, allocator)
	for k in 0..<3 {
		binary_store_f32(out, k*4, lo[k], .Big)
		binary_store_f32(out, 12+k*4, hi[k], .Big)
	}
	return out
}

pssg_identity_bytes :: proc(allocator := context.allocator) -> []u8 {
	out := make([]u8, 64, allocator)
	for k in 0..<4 { binary_store_f32(out, k*20, 1, .Big) }
	return out
}

// Every scene node carries a transform and a box, in that order.
pssg_frame :: proc(types: ^Pssg_Types, lo, hi: [3]f32, allocator := context.allocator) -> (out: [2]^Pssg_Node, msg: string, ok: bool) {
	transform, tmsg, tok := pssg_make(types, "TRANSFORM", nil, nil, pssg_identity_bytes(allocator), allocator)
	if !tok { return out, tmsg, false }
	box, bmsg, bok := pssg_make(types, "BOUNDINGBOX", nil, nil, pssg_box_bytes(lo, hi, allocator), allocator)
	if !bok { pssg_node_delete(transform, allocator); return out, bmsg, false }
	return {transform, box}, "", true
}
