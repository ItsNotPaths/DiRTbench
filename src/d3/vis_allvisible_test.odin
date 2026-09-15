package d3

import "core:testing"

@(test)
ornaments_xml_instance_ids_reads_every_instance_in_file_order :: proc(t: ^testing.T) {
	data := transmute([]u8)string(
		`<instancedata>` + "\r\n" +
		`  <instancelist bounds_min="0 0 0 1" bounds_max="1 1 1 1" reference_num="1" instance_num="2">` + "\r\n" +
		`    <instanceref reference_id="0" filename="pole_mesh" />` + "\r\n" +
		`    <instance transform="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 " colour="0 0 0 1" instance_tag="441419" instance_id="464" reference_id="0" />` + "\r\n" +
		`    <instance transform="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 " colour="0 0 0 1" instance_tag="13" instance_id="588" reference_id="0" />` + "\r\n" +
		`  </instancelist>` + "\r\n" +
		`</instancedata>`,
	)
	ids, ok := d3_ornaments_xml_instance_ids(data, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(ids), 2)
	testing.expect_value(t, ids[0], u32(464))
	testing.expect_value(t, ids[1], u32(588))
}

@(test)
ornaments_xml_instance_ids_fails_closed_without_the_attribute :: proc(t: ^testing.T) {
	data := transmute([]u8)string(
		`<instance transform="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 " colour="0 0 0 1" instance_tag="13" reference_id="0" />` + "\r\n",
	)
	_, ok := d3_ornaments_xml_instance_ids(data, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
ornaments_xml_instance_ids_is_empty_for_a_file_with_no_instances :: proc(t: ^testing.T) {
	data := transmute([]u8)string(`<instancedata><instancelist></instancelist></instancedata>`)
	ids, ok := d3_ornaments_xml_instance_ids(data, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(ids), 0)
}
