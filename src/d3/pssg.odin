package d3

// Lossless Dirt 3 PSSG container support. The schema and leaf payloads borrow
// the input buffer; nodes and attribute lists are allocated. Numeric ids are
// retained deliberately: attribute ids are scoped to their node type, and a
// name-only rebuild can produce a file that round-trips but draws nothing.

import "core:fmt"
import "core:mem"

Pssg_Attr :: struct {
	type_id: u32,
	value:   []u8,
	owned:   bool,
}

Pssg_Node :: struct {
	type_id:  u32,
	name:     string,
	attrs:    [dynamic]Pssg_Attr,
	children: [dynamic]^Pssg_Node,
	data:     []u8,
	data_owned: bool,
}

Pssg_File :: struct {
	schema:     []u8,
	node_names: map[u32]string,
	attr_names: map[u32]string,
	root:       ^Pssg_Node,
}

pssg_be_u32 :: proc(data: []u8, at: int) -> (u32, bool) {
	if !binary_range(len(data), at, 4) { return 0, false }
	return u32(data[at])<<24 | u32(data[at+1])<<16 | u32(data[at+2])<<8 | u32(data[at+3]), true
}

Pssg_Reader :: struct {
	data: []u8,
	at:   int,
}

pssg_take :: proc(r: ^Pssg_Reader, size: int) -> ([]u8, bool) {
	if !binary_range(len(r.data), r.at, size) { return nil, false }
	out := r.data[r.at:r.at+size]
	r.at += size
	return out, true
}

pssg_u32 :: proc(r: ^Pssg_Reader) -> (u32, bool) {
	v, ok := pssg_be_u32(r.data, r.at)
	if ok { r.at += 4 }
	return v, ok
}

pssg_name :: proc(r: ^Pssg_Reader) -> (string, bool) {
	size, ok := pssg_u32(r)
	if !ok || u64(size) > u64(max(int)) { return "", false }
	raw, took := pssg_take(r, int(size))
	if !took { return "", false }
	end := len(raw)
	for end > 0 && raw[end-1] == 0 { end -= 1 }
	return string(raw[:end]), true
}

pssg_node_delete :: proc(node: ^Pssg_Node, allocator := context.allocator) {
	if node == nil { return }
	for child in node.children { pssg_node_delete(child, allocator) }
	for attr in node.attrs { if attr.owned { delete(attr.value, allocator) } }
	if node.data_owned { delete(node.data, allocator) }
	delete(node.attrs)
	delete(node.children)
	free(node, allocator)
}

pssg_delete :: proc(file: ^Pssg_File, allocator := context.allocator) {
	pssg_node_delete(file.root, allocator)
	delete(file.node_names)
	delete(file.attr_names)
	file^ = {}
}

pssg_read_node :: proc(r: ^Pssg_Reader, file: ^Pssg_File, limit: int, allocator: mem.Allocator) -> (^Pssg_Node, string, bool) {
	start := r.at
	type_id, tok := pssg_u32(r)
	size, sok := pssg_u32(r)
	name, known := file.node_names[type_id]
	if !tok || !sok || !known || u64(size) > u64(max(int)) || !binary_range(limit, r.at, int(size)) {
		return nil, fmt.tprintf("invalid PSSG node at 0x%x", start), false
	}
	end := r.at + int(size)
	attr_size, aok := pssg_u32(r)
	if !aok || u64(attr_size) > u64(max(int)) || !binary_range(end, r.at, int(attr_size)) {
		return nil, fmt.tprintf("invalid attributes in PSSG %s", name), false
	}
	node := new(Pssg_Node, allocator)
	node.type_id = type_id
	node.name = name
	node.attrs = make([dynamic]Pssg_Attr, allocator)
	node.children = make([dynamic]^Pssg_Node, allocator)
	attr_end := r.at + int(attr_size)
	for r.at < attr_end {
		aid, iok := pssg_u32(r)
		length, lok := pssg_u32(r)
		if !iok || !lok || u64(length) > u64(max(int)) {
			pssg_node_delete(node, allocator); return nil, fmt.tprintf("invalid attribute in PSSG %s", name), false
		}
		value, vok := pssg_take(r, int(length))
		if !vok || r.at > attr_end {
			pssg_node_delete(node, allocator); return nil, fmt.tprintf("attribute exceeds PSSG %s", name), false
		}
		append(&node.attrs, Pssg_Attr{type_id=aid, value=value})
	}
	if r.at != attr_end {
		pssg_node_delete(node, allocator); return nil, fmt.tprintf("misaligned attributes in PSSG %s", name), false
	}
	// Nothing in a node record says whether the body holds children or a leaf
	// payload, and a payload can open with bytes that read as a node header: an
	// index run starting 0,1,2 does. Only a child list that tiles the body
	// exactly is believed; anything else is taken as data.
	if r.at < end {
		body := r.at
		child_id, ciok := pssg_be_u32(r.data, r.at)
		child_size, csok := pssg_be_u32(r.data, r.at+4)
		_, child_known := file.node_names[child_id]
		if ciok && csok && child_known && u64(child_size) <= u64(max(int)) && binary_range(end, r.at+8, int(child_size)) {
			for r.at < end {
				child, _, ok := pssg_read_node(r, file, end, allocator)
				if !ok { break }
				append(&node.children, child)
			}
		}
		if r.at != end {
			for child in node.children { pssg_node_delete(child, allocator) }
			clear(&node.children)
			r.at = body
			node.data, _ = pssg_take(r, end-r.at)
		}
	}
	if r.at != end {
		pssg_node_delete(node, allocator); return nil, fmt.tprintf("misaligned PSSG node %s", name), false
	}
	return node, "", true
}

pssg_read :: proc(data: []u8, allocator := context.allocator) -> (file: Pssg_File, msg: string, ok: bool) {
	if len(data) < 8 || string(data[:4]) != "PSSG" { return file, "not a PSSG file", false }
	declared, dok := pssg_be_u32(data, 4)
	if !dok || u64(declared) != u64(len(data)-8) { return file, "PSSG file-size field does not match", false }
	r := Pssg_Reader{data=data, at=8}
	schema_at := r.at
	_, aok := pssg_u32(&r) // total attribute-name count
	type_count, tok := pssg_u32(&r)
	if !aok || !tok || u64(type_count) > u64(len(data)/12) { return file, "invalid PSSG schema header", false }
	file.node_names = make(map[u32]string, allocator)
	file.attr_names = make(map[u32]string, allocator)
	for _ in 0..<int(type_count) {
		type_id, iok := pssg_u32(&r)
		name, nok := pssg_name(&r)
		attr_count, cok := pssg_u32(&r)
		if !iok || !nok || !cok || u64(attr_count) > u64(len(data)/12) { pssg_delete(&file, allocator); return file, "invalid PSSG schema type", false }
		file.node_names[type_id] = name
		for _ in 0..<int(attr_count) {
			attr_id, aiok := pssg_u32(&r)
			attr_name, anok := pssg_name(&r)
			if !aiok || !anok { pssg_delete(&file, allocator); return file, "invalid PSSG schema attribute", false }
			file.attr_names[attr_id] = attr_name
		}
	}
	file.schema = data[schema_at:r.at]
	file.root, msg, ok = pssg_read_node(&r, &file, len(data), allocator)
	if !ok { pssg_delete(&file, allocator); return file, msg, false }
	if r.at != len(data) { pssg_delete(&file, allocator); return file, "PSSG has trailing bytes", false }
	return file, "", true
}

pssg_write_node :: proc(w: ^Binary_Writer, node: ^Pssg_Node) -> bool {
	if node == nil { w.ok = false; return false }
	if !binary_write_u32(w, node.type_id, .Big) { return false }
	body_at, reserved := binary_reserve(w, 4); if !reserved { return false }
	body_start := len(w.data)
	attrs_at, reserved_attrs := binary_reserve(w, 4); if !reserved_attrs { return false }
	attrs_start := len(w.data)
	for attr in node.attrs {
		if !binary_write_u32(w, attr.type_id, .Big) || !binary_write_u32(w, u32(len(attr.value)), .Big) { return false }
		_, wrote := binary_write(w, attr.value); if !wrote { return false }
	}
	if !binary_patch_u32(w, attrs_at, u32(len(w.data)-attrs_start), .Big) { return false }
	if len(node.children) > 0 {
		for child in node.children { if !pssg_write_node(w, child) { return false } }
	} else {
		_, wrote := binary_write(w, node.data); if !wrote { return false }
	}
	return binary_patch_u32(w, body_at, u32(len(w.data)-body_start), .Big)
}

pssg_write :: proc(file: ^Pssg_File, allocator := context.allocator) -> ([]u8, bool) {
	w := binary_writer(allocator)
	_, wrote_magic := binary_write(&w, []u8{'P','S','S','G'}); if !wrote_magic { binary_writer_delete(&w); return nil, false }
	size_at, reserved := binary_reserve(&w, 4); if !reserved { binary_writer_delete(&w); return nil, false }
	_, wrote_schema := binary_write(&w, file.schema); if !wrote_schema || !pssg_write_node(&w, file.root) || !binary_patch_u32(&w, size_at, u32(len(w.data)-8), .Big) {
		binary_writer_delete(&w); return nil, false
	}
	return w.data[:], true
}

pssg_attr_string :: proc(file: ^Pssg_File, node: ^Pssg_Node, name: string) -> string {
	if node == nil { return "" }
	for attr in node.attrs {
		attr_name, known := file.attr_names[attr.type_id]
		if !known || attr_name != name || len(attr.value) < 4 { continue }
		size, ok := pssg_be_u32(attr.value, 0)
		if !ok || u64(size) > u64(len(attr.value)-4) { return "" }
		return string(attr.value[4:4+int(size)])
	}
	return ""
}

pssg_attr_u32 :: proc(file:^Pssg_File,node:^Pssg_Node,name:string)->(u32,bool){
	if node==nil{return 0,false}
	for attr in node.attrs { n,k:=file.attr_names[attr.type_id]; if k&&n==name&&len(attr.value)==4{return pssg_be_u32(attr.value,0)} }; return 0,false
}

pssg_set_attr_u32 :: proc(file:^Pssg_File,node:^Pssg_Node,name:string,value:u32,allocator:=context.allocator)->bool{
	if node==nil{return false}
	for &attr in node.attrs { n,k:=file.attr_names[attr.type_id]; if !k||n!=name{continue}; if attr.owned{delete(attr.value,allocator)}; attr.value=make([]u8,4,allocator); attr.owned=true; return binary_store_u32(attr.value,0,value,.Big) }; return false
}

pssg_set_attr_string :: proc(file:^Pssg_File,node:^Pssg_Node,name,value:string,allocator:=context.allocator)->bool{
	if node==nil{return false}
	for &attr in node.attrs { n,k:=file.attr_names[attr.type_id]; if !k||n!=name{continue}; if attr.owned{delete(attr.value,allocator)}; attr.value=make([]u8,4+len(value),allocator); attr.owned=true; binary_store_u32(attr.value,0,u32(len(value)),.Big); copy(attr.value[4:],transmute([]u8)value); return true }; return false
}

pssg_walk_first :: proc(node:^Pssg_Node,name:string)->^Pssg_Node{
	if node==nil{return nil}; if node.name==name{return node}; for child in node.children { if found:=pssg_walk_first(child,name); found!=nil{return found} }; return nil
}
