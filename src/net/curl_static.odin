#+build windows
package net

// Windows ships no libcurl.dll, so our own build is linked in. It uses Schannel,
// so TLS and the certificate store are the OS's own. download-deps.sh builds it.

import "core:c"
import "core:sync"

// curl's own dependency list, from its CMakeLists.
foreign import curl_lib {
	"../../vendor/curl/libcurl.lib",
	"system:ws2_32.lib",
	"system:iphlpapi.lib",
	"system:bcrypt.lib",
	"system:advapi32.lib",
	"system:crypt32.lib",
	"system:secur32.lib",
}

@(default_calling_convention = "c")
foreign curl_lib {
	curl_global_init   :: proc(flags: c.long) -> c.int ---
	curl_easy_init     :: proc() -> rawptr ---
	curl_easy_cleanup  :: proc(handle: rawptr) ---
	curl_easy_perform  :: proc(handle: rawptr) -> c.int ---
	curl_easy_strerror :: proc(code: c.int) -> cstring ---
	curl_easy_setopt   :: proc(handle: rawptr, opt: c.int, #c_vararg args: ..any) -> c.int ---
	curl_easy_getinfo  :: proc(handle: rawptr, info: c.int, #c_vararg args: ..any) -> c.int ---
	curl_mime_init     :: proc(handle: rawptr) -> rawptr ---
	curl_mime_free     :: proc(mime: rawptr) ---
	curl_mime_addpart  :: proc(mime: rawptr) -> rawptr ---
	curl_mime_name     :: proc(part: rawptr, name: cstring) -> c.int ---
	curl_mime_data     :: proc(part: rawptr, data: [^]u8, size: c.size_t) -> c.int ---
	curl_mime_filedata :: proc(part: rawptr, path: cstring) -> c.int ---
	curl_mime_filename :: proc(part: rawptr, name: cstring) -> c.int ---
	curl_mime_type     :: proc(part: rawptr, mime: cstring) -> c.int ---
	curl_slist_append  :: proc(list: rawptr, line: cstring) -> rawptr ---
	curl_slist_free_all :: proc(list: rawptr) ---
}

@(private)
curl_once: sync.Once

@(private)
curl_load :: proc() {
	sync.once_do(&curl_once, proc() {
		curl = Curl {
			ready          = true,
			global_init    = curl_global_init,
			easy_init      = curl_easy_init,
			easy_cleanup   = curl_easy_cleanup,
			easy_perform   = curl_easy_perform,
			easy_strerror  = curl_easy_strerror,
			setopt_str     = proc "c" (h: rawptr, opt: c.int, val: cstring) -> c.int {return curl_easy_setopt(h, opt, val)},
			setopt_long    = proc "c" (h: rawptr, opt: c.int, val: c.long) -> c.int {return curl_easy_setopt(h, opt, val)},
			setopt_ptr     = proc "c" (h: rawptr, opt: c.int, val: rawptr) -> c.int {return curl_easy_setopt(h, opt, val)},
			getinfo_long   = proc "c" (h: rawptr, info: c.int, out: ^c.long) -> c.int {return curl_easy_getinfo(h, info, out)},
			mime_init      = curl_mime_init,
			mime_free      = curl_mime_free,
			mime_addpart   = curl_mime_addpart,
			mime_name      = curl_mime_name,
			mime_data      = curl_mime_data,
			mime_filedata  = curl_mime_filedata,
			mime_filename  = curl_mime_filename,
			mime_type      = curl_mime_type,
			slist_append   = curl_slist_append,
			slist_free_all = curl_slist_free_all,
		}
		curl.global_init(GLOBAL_DEFAULT)
	})
}
