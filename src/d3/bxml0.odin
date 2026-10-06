package d3

import "core:fmt"
import "core:strconv"
import "core:strings"

// The `\0BXML` container: game-mode triggers, crowds, cloth, wind. Unrelated to
// the BinXML in binxml.odin. See docs/dirt3-binxml.md, "The other one".
//
// After the 5-byte magic, every record is a u16be size and that many bytes. An
// element record is a u32be attribute count, its NUL-terminated name, then
// NUL-terminated attribute/value pairs; its children follow, then a close
// record (body 05 00 00 00). Every file in the install ends with two 06 records.

BXML0_MAGIC :: "\x00BXML"
BXML0_CLOSE :: u8(5)
BXML0_END   :: u8(6)

Bxml0_Node :: struct {
	name:     string,
	attrs:    []Bxml_Attr,
	children: [dynamic]^Bxml0_Node,
}

bxml0_node :: proc(name: string, attrs: ..Bxml_Attr, allocator := context.temp_allocator) -> ^Bxml0_Node {
	node := new(Bxml0_Node, allocator)
	node^ = {name = name, attrs = make([]Bxml_Attr, len(attrs), allocator), children = make([dynamic]^Bxml0_Node, allocator)}
	copy(node.attrs, attrs)
	return node
}

// The one top element. Strings slice `data`.
d3_bxml0_read :: proc(data: []u8, allocator := context.temp_allocator) -> (root: ^Bxml0_Node, msg: string, ok: bool) {
	if len(data) < len(BXML0_MAGIC) || string(data[:len(BXML0_MAGIC)]) != BXML0_MAGIC {
		return nil, "not a \\0BXML file", false
	}
	stack := make([dynamic]^Bxml0_Node, context.temp_allocator)
	ends := 0
	p := len(BXML0_MAGIC)
	for p < len(data) {
		if p + 2 > len(data) { return nil, "truncated record", false }
		size := int(data[p]) << 8 | int(data[p+1])
		body_at := p + 2
		p = body_at + size
		if p > len(data) || size < 4 { return nil, fmt.tprintf("bad record at %d", body_at - 2), false }
		body := data[body_at:p]
		if size == 4 && body[1] == 0 && body[2] == 0 && body[3] == 0 && (body[0] == BXML0_CLOSE || body[0] == BXML0_END) {
			if body[0] == BXML0_END {
				ends += 1
			} else if len(stack) == 0 || ends > 0 {
				return nil, "a close with nothing open", false
			} else {
				pop(&stack)
			}
			continue
		}
		if ends > 0 { return nil, "an element after the end", false }
		count := int(body[0]) << 24 | int(body[1]) << 16 | int(body[2]) << 8 | int(body[3])
		strs := make([dynamic]string, 0, 1 + 2*count, context.temp_allocator)
		start := 4
		for i in 4 ..< len(body) {
			if body[i] == 0 {
				append(&strs, string(body[start:i]))
				start = i + 1
			}
		}
		if start != len(body) || len(strs) != 1 + 2*count {
			return nil, fmt.tprintf("bad element record at %d", body_at - 2), false
		}
		node := bxml0_node(strs[0], allocator = allocator)
		node.attrs = make([]Bxml_Attr, count, allocator)
		for i in 0 ..< count {
			node.attrs[i] = {strs[1 + 2*i], strs[2 + 2*i]}
		}
		if len(stack) > 0 {
			append(&stack[len(stack) - 1].children, node)
		} else if root != nil {
			return nil, "a second top element", false
		} else {
			root = node
		}
		append(&stack, node)
	}
	if root == nil || len(stack) != 0 || ends != 2 {
		return nil, "the file does not close", false
	}
	return root, "", true
}

d3_bxml0_write :: proc(root: ^Bxml0_Node, allocator := context.allocator) -> (data: []u8, ok: bool) {
	out := make([dynamic]u8, allocator)
	append(&out, BXML0_MAGIC)
	if !bxml0_write_node(&out, root) {
		delete(out)
		return nil, false
	}
	for _ in 0 ..< 2 {
		append(&out, 0, 4, BXML0_END, 0, 0, 0)
	}
	return out[:], true
}

@(private = "file")
bxml0_write_node :: proc(out: ^[dynamic]u8, node: ^Bxml0_Node) -> bool {
	size := 4 + len(node.name) + 1
	for a in node.attrs {
		size += len(a.name) + 1 + len(a.value) + 1
	}
	if size > 0xffff { return false }
	n := len(node.attrs)
	append(out, u8(size >> 8), u8(size), u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	append(out, node.name); append(out, 0)
	for a in node.attrs {
		append(out, a.name); append(out, 0)
		append(out, a.value); append(out, 0)
	}
	for child in node.children {
		if !bxml0_write_node(out, child) { return false }
	}
	append(out, 0, 4, BXML0_CLOSE, 0, 0, 0)
	return true
}

// --- Transporter --------------------------------------------------------------

// A flag or a drop zone. `post` is the trigger's `instance_id`; it appears to
// be the `component_transporter` row, the height of the marker post.
D3_Transporter_Goal :: struct {
	pos:       [3]f32,
	drop_zone: bool,
	post:      i32,
}

d3_transporter_triggers :: proc(goals: []D3_Transporter_Goal, allocator := context.allocator) -> (data: []u8, ok: bool) {
	root := bxml0_node("triggers")
	for goal, i in goals {
		value :: proc(type, name, v: string) -> ^Bxml0_Node {
			return bxml0_node("value", {"type", type}, {"name", name}, {"value", v})
		}
		params := bxml0_node("params")
		append(&params.children,
			value("vector4", "position", fmt.tprintf("%v, %v, %v, 1", goal.pos[0], goal.pos[1], goal.pos[2])),
			value("dstring", "template", goal.drop_zone ? "DropZone" : "Flag"),
			value("int32", "instance_id", fmt.tprint(goal.post)),
		)
		trigger := bxml0_node("trigger", {"type", "GameObjectTrigger"})
		append(&trigger.children,
			bxml0_node("base_params", {"name", fmt.tprintf("gameobject_transporter_%d", i)}, {"id", fmt.tprint(i)}),
			params,
		)
		append(&root.children, trigger)
	}
	return d3_bxml0_write(root, allocator)
}

// The goals of a stock triggers_transporter.xml.
d3_transporter_goals :: proc(data: []u8, allocator := context.allocator) -> (goals: []D3_Transporter_Goal, msg: string, ok: bool) {
	root, read_msg, read_ok := d3_bxml0_read(data)
	if !read_ok { return nil, read_msg, false }
	out := make([dynamic]D3_Transporter_Goal, 0, len(root.children), allocator)
	for trigger in root.children {
		goal: D3_Transporter_Goal
		template := ""
		for child in trigger.children {
			if child.name != "params" { continue }
			for v in child.children {
				name, value := bxml0_attr(v, "name"), bxml0_attr(v, "value")
				switch name {
				case "position":
					parts := strings.split(value, ",", context.temp_allocator)
					if len(parts) != 4 {
						delete(out)
						return nil, fmt.tprintf("bad position %q", value), false
					}
					for k in 0 ..< 3 {
						goal.pos[k], _ = strconv.parse_f32(strings.trim_space(parts[k]))
					}
				case "template":
					template = value
				case "instance_id":
					post, _ := strconv.parse_int(value)
					goal.post = i32(post)
				}
			}
		}
		if template != "Flag" && template != "DropZone" { continue }
		goal.drop_zone = template == "DropZone"
		append(&out, goal)
	}
	return out[:], "", true
}

bxml0_attr :: proc(node: ^Bxml0_Node, name: string) -> string {
	for a in node.attrs {
		if a.name == name { return a.value }
	}
	return ""
}
