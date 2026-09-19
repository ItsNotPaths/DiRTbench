package net

// One HTTP request shape: a multipart POST, which is all dirtbench asks of the
// network.
//
// libcurl is opened at runtime rather than linked. The binary depends on libc
// and libm and nothing else, and `-lcurl` would add libcurl.so.4 plus the ssl,
// crypto, nghttp2, zstd and brotli it drags behind it. Opening it instead keeps
// that list empty and makes the dependency optional: a machine without libcurl
// loses upload and keeps the tool.
//
// Nothing here knows what dirtbench.paths.place wants. The form is the caller's.

import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:strings"
import "core:sync"

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
INFO_RESPONSE_CODE :: 2097154

GLOBAL_DEFAULT :: 3

// curl_easy_setopt and curl_easy_getinfo are variadic in C, and a variadic call
// cannot be made through one typed pointer. Three aliases of the same symbol,
// one per argument shape, is the ordinary way to bind them.
Curl :: struct {
	lib: dynlib.Library,

	global_init:  proc "c" (flags: c.long) -> c.int,
	easy_init:    proc "c" () -> rawptr,
	easy_cleanup: proc "c" (handle: rawptr),
	easy_perform: proc "c" (handle: rawptr) -> c.int,
	easy_strerror: proc "c" (code: c.int) -> cstring,

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
}

// The sonames to try, in order. One per platform; the others simply do not open.
LIB_NAMES :: []string{"libcurl.so.4", "libcurl.so", "libcurl.4.dylib", "libcurl.dylib", "libcurl.dll"}

@(private)
curl: Curl
@(private)
curl_once: sync.Once

// Open libcurl once per process. Every entry point goes through this, so a
// machine without it answers the same way however it is asked.
@(private)
curl_load :: proc() {
	sync.once_do(&curl_once, proc() {
		for name in LIB_NAMES {
			if lib, ok := dynlib.load_library(name); ok {
				curl.lib = lib
				break
			}
		}
		if curl.lib == nil {
			return
		}
		bind :: proc(dst: rawptr, name: string) -> bool {
			addr, found := dynlib.symbol_address(curl.lib, name)
			if !found {
				return false
			}
			(^rawptr)(dst)^ = addr
			return true
		}
		// Every symbol, or none: a partial binding would fault at the first gap
		// instead of reporting a missing library.
		all := bind(&curl.global_init, "curl_global_init") &&
			bind(&curl.easy_init, "curl_easy_init") &&
			bind(&curl.easy_cleanup, "curl_easy_cleanup") &&
			bind(&curl.easy_perform, "curl_easy_perform") &&
			bind(&curl.easy_strerror, "curl_easy_strerror") &&
			bind(&curl.setopt_str, "curl_easy_setopt") &&
			bind(&curl.setopt_long, "curl_easy_setopt") &&
			bind(&curl.setopt_ptr, "curl_easy_setopt") &&
			bind(&curl.getinfo_long, "curl_easy_getinfo") &&
			bind(&curl.mime_init, "curl_mime_init") &&
			bind(&curl.mime_free, "curl_mime_free") &&
			bind(&curl.mime_addpart, "curl_mime_addpart") &&
			bind(&curl.mime_name, "curl_mime_name") &&
			bind(&curl.mime_data, "curl_mime_data") &&
			bind(&curl.mime_filedata, "curl_mime_filedata") &&
			bind(&curl.mime_filename, "curl_mime_filename") &&
			bind(&curl.mime_type, "curl_mime_type")
		if !all {
			curl.lib = nil
			return
		}
		curl.global_init(GLOBAL_DEFAULT)
	})
}

// Whether this machine can make a request at all. The caller greys its button
// with this rather than letting the user find out by pressing it.
available :: proc() -> bool {
	curl_load()
	return curl.lib != nil
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
	curl_load()
	if curl.lib == nil {
		return {}, "libcurl is not installed on this machine", .No_Library
	}
	handle := curl.easy_init()
	if handle == nil {
		return {}, "libcurl would not start", .No_Handle
	}
	defer curl.easy_cleanup(handle)

	mime := curl.mime_init(handle)
	defer curl.mime_free(mime)
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

	body := make([dynamic]u8, 0, 4096, allocator)
	curl.setopt_str(handle, OPT_URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl.setopt_str(handle, OPT_USERAGENT, "dirtbench")
	curl.setopt_ptr(handle, OPT_MIMEPOST, mime)
	curl.setopt_ptr(handle, OPT_WRITEFUNCTION, rawptr(write_cb))
	curl.setopt_ptr(handle, OPT_WRITEDATA, &body)
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
	// Cloned rather than handed over: the buffer grew to a capacity the caller
	// would not be freeing.
	return Response{status = int(status), body = strings.clone(string(body[:]), allocator)}, "", .None
}
