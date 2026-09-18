package d3

// Codemasters BinXML writer. The ordering is part of the format: strings are
// interned on first encounter, while sibling element records are reserved
// together before recursively laying out their descendants.

BXML_FILE       :: u32(0x7252221A)
BXML_TABLE      :: u32(0x72522217)
BXML_STRINGS    :: u32(0x7252221D)
BXML_OFFSETS    :: u32(0x7252221E)
BXML_ELEMENTS   :: u32(0x7252221B)
BXML_ATTRIBUTES :: u32(0x7252221C)

Bxml_Attr :: struct { name, value: string }

Bxml_Content :: enum {
	Empty,
	Text,
	Children,
}

Bxml_Node :: struct {
	name:    string,
	attrs:   []Bxml_Attr,
	content: Bxml_Content,
	text:    string,
	children: []^Bxml_Node,
}

Bxml_Record :: struct {
	value: [6]u32,
	filled: bool,
}

Bxml_Pair :: [2]u32

bxml_content_valid :: proc(node:^Bxml_Node) -> bool {
	switch node.content {
	case .Empty:    return node.text=="" && len(node.children)==0
	case .Text:     return len(node.children)==0
	case .Children: return node.text=="" && len(node.children)>0
	}
	return false
}

bxml_slot_valid :: proc(node:^Bxml_Node,slot,count:int) -> bool {
	return node!=nil && node.name!="" && slot>=0 && slot<count
}

bxml_node :: proc(name: string, attrs: []Bxml_Attr = nil, children: []^Bxml_Node = nil, allocator := context.temp_allocator) -> ^Bxml_Node {
	n := new(Bxml_Node, allocator)
	n.name = name
	if len(attrs)>0 {
		n.attrs=make([]Bxml_Attr,len(attrs),allocator)
		copy(n.attrs,attrs)
	}
	if len(children)>0 {
		n.content = .Children
		n.children=make([]^Bxml_Node,len(children),allocator)
		copy(n.children,children)
	}
	return n
}

// Attributes as a call rather than a slice literal, so a node reads on one
// line. `bxml_node` copies, so the returned slice is the caller's to drop.
bxml_attrs :: proc(pairs: ..Bxml_Attr, allocator := context.temp_allocator) -> []Bxml_Attr {
	out := make([]Bxml_Attr, len(pairs), allocator)
	copy(out, pairs)
	return out
}

bxml_text :: proc(name, text: string, attrs: []Bxml_Attr = nil, allocator := context.temp_allocator) -> ^Bxml_Node {
	n := bxml_node(name, attrs, nil, allocator)
	n.text, n.content = text, .Text
	return n
}

bxml_layout :: proc(
	node: ^Bxml_Node,
	slot: int,
	records: ^[dynamic]Bxml_Record,
	pairs: ^[dynamic]Bxml_Pair,
	strings: ^Binary_String_Table,
) -> bool {
	if !bxml_slot_valid(node,slot,len(records)) || !bxml_content_valid(node) {
		return false
	}
	name_id := binary_string_intern(strings, node.name)
	attr_start := 0
	if len(node.attrs) > 0 { attr_start = len(pairs) }
	for attr in node.attrs {
		append(pairs, Bxml_Pair{u32(binary_string_intern(strings, attr.name)), u32(binary_string_intern(strings, attr.value))})
	}
	child_start := len(records)
	value_id := 0
	if node.content == .Text {
		value_id = binary_string_intern(strings, node.text)
	} else if node.content == .Children {
		for _ in node.children { append(records, Bxml_Record{}) }
		for child, i in node.children {
			if !bxml_layout(child, child_start+i, records, pairs, strings) { return false }
		}
	}
	records[slot] = Bxml_Record{
		value = {u32(name_id), u32(value_id), u32(len(node.attrs)), u32(attr_start), u32(len(node.children)), u32(child_start)},
		filled = true,
	}
	return true
}

bxml_build :: proc(root: ^Bxml_Node, allocator := context.allocator) -> (data: []u8, ok: bool) {
	if root == nil { return nil, false }
	records := make([dynamic]Bxml_Record, allocator); defer delete(records)
	pairs := make([dynamic]Bxml_Pair, allocator); defer delete(pairs)
	strings := binary_string_table(allocator); defer binary_string_table_delete(&strings)
	append(&records, Bxml_Record{})
	if !bxml_layout(root, 0, &records, &pairs, &strings) { return nil, false }
	for record in records { if !record.filled { return nil, false } }

	string_size := 0
	for value in strings.values { string_size += len(value)+1 }
	// The offset array begins aligned to 16 bytes, after its 8-byte header.
	remainder := (24 + string_size) % 16
	padding := 8-remainder
	if remainder > 8 { padding = 24-remainder }
	strings_payload := string_size+padding
	table_size := strings_payload + len(strings.values)*4 + 16
	total := 16 + 8+strings_payload + 8+len(strings.values)*4 + 8+len(records)*24 + 8+len(pairs)*8

	w := binary_writer(allocator)
	defer binary_writer_delete(&w)
	binary_write_u32(&w, BXML_FILE); binary_write_u32(&w, u32(total-8))
	binary_write_u32(&w, BXML_TABLE); binary_write_u32(&w, u32(table_size))
	binary_write_u32(&w, BXML_STRINGS); binary_write_u32(&w, u32(strings_payload))
	offset: u32 = 0
	for value in strings.values {
		binary_write_string(&w, value, true)
		offset += u32(len(value)+1)
	}
	_, _ = binary_reserve(&w, padding)
	binary_write_u32(&w, BXML_OFFSETS); binary_write_u32(&w, u32(len(strings.values)*4))
	offset = 0
	for value in strings.values {
		binary_write_u32(&w, offset)
		offset += u32(len(value)+1)
	}
	binary_write_u32(&w, BXML_ELEMENTS); binary_write_u32(&w, u32(len(records)*24))
	for record in records { for value in record.value { binary_write_u32(&w, value) } }
	binary_write_u32(&w, BXML_ATTRIBUTES); binary_write_u32(&w, u32(len(pairs)*8))
	for pair in pairs { binary_write_u32(&w, pair[0]); binary_write_u32(&w, pair[1]) }
	if !w.ok || len(w.data) != total { return nil, false }
	data = make([]u8, len(w.data), allocator)
	copy(data, w.data[:])
	return data, true
}
