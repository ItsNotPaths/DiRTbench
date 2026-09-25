#+build !windows
package net

// libcurl is opened at runtime rather than linked. The binary depends on libc
// and libm and nothing else, and `-lcurl` would add libcurl.so.4 plus the ssl,
// crypto, nghttp2, zstd and brotli it drags behind it. Opening it instead keeps
// that list empty and makes the dependency optional: a machine without libcurl
// loses upload and browsing, and keeps the tool.

import "core:dynlib"
import "core:sync"

// The sonames to try, in order. One per platform; the others simply do not open.
LIB_NAMES :: []string{"libcurl.so.4", "libcurl.so", "libcurl.4.dylib", "libcurl.dylib"}

@(private)
curl_lib: dynlib.Library
@(private)
curl_once: sync.Once

// Open libcurl once per process. Every entry point goes through this, so a
// machine without it answers the same way however it is asked.
@(private)
curl_load :: proc() {
	sync.once_do(&curl_once, proc() {
		for name in LIB_NAMES {
			if lib, ok := dynlib.load_library(name); ok {
				curl_lib = lib
				break
			}
		}
		if curl_lib == nil {
			return
		}
		bind :: proc(dst: rawptr, name: string) -> bool {
			addr, found := dynlib.symbol_address(curl_lib, name)
			if !found {
				return false
			}
			(^rawptr)(dst)^ = addr
			return true
		}
		// Every symbol, or none: a partial binding would fault at the first gap
		// instead of reporting a missing library.
		curl.ready = bind(&curl.global_init, "curl_global_init") &&
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
			bind(&curl.mime_type, "curl_mime_type") &&
			bind(&curl.slist_append, "curl_slist_append") &&
			bind(&curl.slist_free_all, "curl_slist_free_all")
		if curl.ready {
			curl.global_init(GLOBAL_DEFAULT)
		}
	})
}
