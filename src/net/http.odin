package net

// The two request shapes dirtbench asks of the network: a multipart POST, which
// publishes a venue, and a GET, which browses and downloads one.
//
// Both go through libcurl. How it arrives differs per platform: curl_dlopen.odin
// opens the system one at runtime, curl_static.odin links our own build in.
//
// Nothing here knows what dirtbench.paths.place wants. The form is the caller's.

import "base:runtime"
import "core:c"
import "core:strings"

// Where a part's bytes come from. A part is one or the other, never both.
Form_Field :: struct {
	name:      string,
	value:     string, // sent literally
	path:      string, // ... unless this is set, and then the file at it is sent
	// Both optional. `filename` is what the server sees; without it libcurl
	// sends the basename of `path`.
	mime:      string,
	filename:  string,
}

Response :: struct {
	status: int,
	body:   string, // whatever the server wrote, 2xx or not
	// The server's ETag, verbatim, or "". Opaque: hand it back on the next
	// request for this URL and never take it apart. mod_deflate rewrites
	// `"abc"` into `W/"abc-gzip"` when it compresses, so the tag that arrives
	// is not the one the server generated and only the server can compare them.
	etag:   string,
}

Error :: enum {
	None,
	No_Library,  // libcurl is not on this machine
	No_Handle,   // libcurl is, but would not start
	Transfer,    // the request itself failed; see the message
}

// --- the library ---------------------------------------------------------------

// libcurl's option and info ids, as curl.h defines them: the type tag times its
// magnitude plus the option's own number.
OPT_WRITEDATA     :: 10001
OPT_URL           :: 10002
OPT_WRITEFUNCTION :: 20011
OPT_TIMEOUT       :: 13
OPT_USERAGENT     :: 10018
OPT_FOLLOWLOCATION :: 52
OPT_CONNECTTIMEOUT :: 78
OPT_NOSIGNAL      :: 99
OPT_MIMEPOST      :: 10269
OPT_HTTPHEADER    :: 10023
OPT_HEADERFUNCTION :: 20079
OPT_HEADERDATA    :: 10029
INFO_RESPONSE_CODE :: 2097154

// What the tool calls itself on the wire. Cloudflare's Browser Integrity Check
// refuses known scripting-library agents with error 1010 before the request
// reaches the origin, so this names the tool, not the client underneath it.
// The build's version belongs to the app, which writes it in at startup.
user_agent: cstring = "DiRTbench (+https://github.com/ItsNotPaths/DiRTbench)"

GLOBAL_DEFAULT :: 3

// The libcurl calls this file makes. Each platform's curl_load fills it.
Curl :: struct {
	ready: bool,

	global_init:  proc "c" (flags: c.long) -> c.int,
	easy_init:    proc "c" () -> rawptr,
	easy_cleanup: proc "c" (handle: rawptr),
	easy_perform: proc "c" (handle: rawptr) -> c.int,
	easy_strerror: proc "c" (code: c.int) -> cstring,

	// curl_easy_setopt and curl_easy_getinfo are variadic in C, so there is one
	// typed entry per argument shape.
	setopt_str:  proc "c" (handle: rawptr, opt: c.int, val: cstring) -> c.int,
	setopt_long: proc "c" (handle: rawptr, opt: c.int, val: c.long) -> c.int,
	setopt_ptr:  proc "c" (handle: rawptr, opt: c.int, val: rawptr) -> c.int,
	getinfo_long: proc "c" (handle: rawptr, info: c.int, out: ^c.long) -> c.int,

	mime_init:     proc "c" (handle: rawptr) -> rawptr,
	mime_free:     proc "c" (mime: rawptr),
	mime_addpart:  proc "c" (mime: rawptr) -> rawptr,
	mime_name:     proc "c" (part: rawptr, name: cstring) -> c.int,
	mime_data:     proc "c" (part: rawptr, data: [^]u8, size: c.size_t) -> c.int,
	mime_filedata: proc "c" (part: rawptr, path: cstring) -> c.int,
	mime_filename: proc "c" (part: rawptr, name: cstring) -> c.int,
	mime_type:     proc "c" (part: rawptr, mime: cstring) -> c.int,

	slist_append:    proc "c" (list: rawptr, line: cstring) -> rawptr,
	slist_free_all:  proc "c" (list: rawptr),
}

@(private)
curl: Curl

// Whether this machine can make a request at all. The caller greys its button
// with this rather than letting the user find out by pressing it.
available :: proc() -> bool {
	curl_load()
	return curl.ready
}

// --- the request ---------------------------------------------------------------

@(private)
write_cb :: proc "c" (ptr: rawptr, size, nmemb: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	buf := (^[dynamic]u8)(user)
	n := int(size) * int(nmemb)
	append(buf, ..(([^]u8)(ptr))[:n])
	return c.size_t(n)
}

// The ETag off the response, kept whole. A redirect chain sends one header
// block per hop, so the last one wins: the tag has to belong to the body that
// came back with it.
@(private)
header_cb :: proc "c" (ptr: rawptr, size, nmemb: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	n := int(size) * int(nmemb)
	line := string((([^]u8)(ptr))[:n])
	ETAG :: "etag:"
	if len(line) > len(ETAG) && strings.equal_fold(line[:len(ETAG)], ETAG) {
		tag := (^[dynamic]u8)(user)
		clear(tag)
		append(tag, ..transmute([]u8)strings.trim_space(line[len(ETAG):]))
	}
	return c.size_t(n)
}

// POST `fields` to `url` as multipart/form-data, and give back whatever came
// out. A 4xx is not an error here: the body carries the server's reason and the
// caller wants to show it.
post_form :: proc(
	url: string,
	fields: []Form_Field,
	timeout_s := 60,
	allocator := context.allocator,
) -> (
	res: Response,
	msg: string,
	err: Error,
) {
	return request(url, fields, timeout_s, allocator)
}

// GET `url`. Same rules as post_form: the body comes back whatever the status
// was, because the status alone never says why.
//
// `etag` is a tag a previous answer to this same URL carried. Sending it back
// asks the server whether anything moved, and an unchanged resource answers 304
// with no body, which is what makes asking again cheap.
get :: proc(
	url: string,
	etag := "",
	timeout_s := 60,
	allocator := context.allocator,
) -> (
	res: Response,
	msg: string,
	err: Error,
) {
	return request(url, nil, timeout_s, allocator, etag)
}

// The one request. `fields` nil is a GET, and anything else a multipart POST:
// everything either shape needs of libcurl is the same but the body.
@(private)
request :: proc(
	url: string,
	fields: []Form_Field,
	timeout_s: int,
	allocator: runtime.Allocator,
	etag := "",
) -> (
	res: Response,
	msg: string,
	err: Error,
) {
	curl_load()
	if !curl.ready {
		return {}, "libcurl is not installed on this machine", .No_Library
	}
	handle := curl.easy_init()
	if handle == nil {
		return {}, "libcurl would not start", .No_Handle
	}
	defer curl.easy_cleanup(handle)

	// A GET builds no body at all: an empty mime is still a POST of nothing.
	mime: rawptr
	defer if mime != nil {
		curl.mime_free(mime)
	}
	if fields != nil {
		mime = curl.mime_init(handle)
		curl.setopt_ptr(handle, OPT_MIMEPOST, mime)
	}
	for f in fields {
		part := curl.mime_addpart(mime)
		curl.mime_name(part, strings.clone_to_cstring(f.name, context.temp_allocator))
		if f.path != "" {
			curl.mime_filedata(part, strings.clone_to_cstring(f.path, context.temp_allocator))
		} else {
			curl.mime_data(part, raw_data(f.value), c.size_t(len(f.value)))
		}
		if f.filename != "" {
			curl.mime_filename(part, strings.clone_to_cstring(f.filename, context.temp_allocator))
		}
		if f.mime != "" {
			curl.mime_type(part, strings.clone_to_cstring(f.mime, context.temp_allocator))
		}
	}

	headers: rawptr
	defer if headers != nil {
		curl.slist_free_all(headers)
	}
	if etag != "" {
		line := strings.concatenate({"If-None-Match: ", etag}, context.temp_allocator)
		headers = curl.slist_append(nil, strings.clone_to_cstring(line, context.temp_allocator))
		curl.setopt_ptr(handle, OPT_HTTPHEADER, headers)
	}

	body := make([dynamic]u8, 0, 4096, allocator)
	tag := make([dynamic]u8, 0, 64, allocator)
	defer delete(tag)
	curl.setopt_str(handle, OPT_URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl.setopt_str(handle, OPT_USERAGENT, user_agent)
	curl.setopt_ptr(handle, OPT_WRITEFUNCTION, rawptr(write_cb))
	curl.setopt_ptr(handle, OPT_WRITEDATA, &body)
	curl.setopt_ptr(handle, OPT_HEADERFUNCTION, rawptr(header_cb))
	curl.setopt_ptr(handle, OPT_HEADERDATA, &tag)
	curl.setopt_long(handle, OPT_FOLLOWLOCATION, 1)
	curl.setopt_long(handle, OPT_TIMEOUT, c.long(timeout_s))
	curl.setopt_long(handle, OPT_CONNECTTIMEOUT, 15)
	// Without this libcurl's resolver timeout arrives as SIGALRM, which lands
	// on whichever thread the OS picks.
	curl.setopt_long(handle, OPT_NOSIGNAL, 1)

	defer delete(body)
	if code := curl.easy_perform(handle); code != 0 {
		return {}, string(curl.easy_strerror(code)), .Transfer
	}
	status: c.long
	curl.getinfo_long(handle, INFO_RESPONSE_CODE, &status)
	// Cloned rather than handed over: the buffers grew to a capacity the caller
	// would not be freeing.
	return Response{
		status = int(status),
		body   = strings.clone(string(body[:]), allocator),
		etag   = strings.clone(string(tag[:]), allocator),
	}, "", .None
}

// --- urls ----------------------------------------------------------------------

// Percent-encode one query-string value. Everything but the RFC 3986 unreserved
// set goes out as %XX, so a search for `rally*` or a name with a space cannot
// change the shape of the URL it is put into.
query_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	hex := "0123456789ABCDEF"
	b := strings.builder_make(allocator)
	strings.builder_grow(&b, len(s))
	for i in 0 ..< len(s) {
		ch := s[i]
		switch {
		case ch >= 'a' && ch <= 'z', ch >= 'A' && ch <= 'Z', ch >= '0' && ch <= '9',
		     ch == '-', ch == '_', ch == '.', ch == '~':
			strings.write_byte(&b, ch)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[ch >> 4])
			strings.write_byte(&b, hex[ch & 0xF])
		}
	}
	return strings.to_string(b)
}
