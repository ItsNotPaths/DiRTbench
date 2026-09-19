package main

// Browsing dirtbench.paths.place, and taking a copy of a venue off it.
//
// The site answers read-only JSON at /api/v1 and serves the venue documents
// themselves as static files behind it. Nothing here needs an account: an
// upload is a claim about who you are, a download is not.
//
// A download is two requests, and both are needed:
//
//   the listing   /api/v1/venues/<slug>, which carries every version, the
//                 sha256 of each, and a download URL that registers the pull.
//   the bytes     that URL. They are checked against that hash before a byte
//                 of them is written, because from the moment they land in
//                 maps/ the tool treats them as a document it wrote itself.
//
// What comes down is stamped with where it came from (Venue_Source), which is
// what stops it being re-published under somebody else's name: the upload panel
// refuses while that stamp is set, and it travels with the file.
//
// The requests run on a thread of their own, one at a time, under the rule
// handoff.odin sets out.

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "../net"

BROWSE_API :: UPLOAD_SITE + "/api/v1"

// Venues per page. The endpoint allows 100 and defaults to 25; a page is a
// screenful, not a sync.
BROWSE_PAGE :: 25

// --- what the site says --------------------------------------------------------

// One venue in a listing. Unknown keys are ignored, so the site may add fields
// without this having to know. `stages` and `length_m` arrive null when the
// server could not measure them, and null reads as zero.
Browse_Listing :: struct {
	slug:         string, // the site's id, and what a download names
	venue_id:     string, // the id the game installs under, and our file name
	title:        string,
	author:       string,
	stages:       int,
	length_m:     int,
	downloads:    int,
	version:      int, // how many versions there are, not which one
	rating:       struct {
		average: f32,
		count:   int,
	},
	page_url:     string,
}

Browse_Page :: struct {
	ok:     bool,
	total:  int,
	page:   int,
	pages:  int,
	venues: []Browse_Listing,
}

// One published version of one venue.
@(private = "file")
Browse_Version :: struct {
	version:      int,
	bytes:        int,
	sha256:       string,
	download_url: string, // counted; the blob URL beside it is not
}

@(private = "file")
Browse_Detail :: struct {
	ok:    bool,
	error: string,
	venue: struct {
		slug:     string,
		venue_id: string,
		title:    string,
		// Newest first, so the head of this is the version to take.
		versions: []Browse_Version,
	},
}

// --- the query -----------------------------------------------------------------

Browse_Sort :: enum {
	New,
	Downloads,
	Rating,
}

// The site's own sort keys, and what the panel calls them.
@(rodata)
BROWSE_SORTS := [Browse_Sort]struct {
	key:   string,
	label: cstring,
}{
	.New       = {"new", "newest"},
	.Downloads = {"downloads", "most downloaded"},
	.Rating    = {"rating", "top rated"},
}

// What the panel is asking for, as a URL. The search text is the site's own
// glob syntax (`pine`, `rally*`, `!loop`, `user: a, b`, `rating:>=4`) and goes
// out escaped, so nothing typed into the box can change the shape of the URL.
browse_url :: proc(
	text: string,
	sort: Browse_Sort,
	page: int,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "%s/venues?limit=%d&sort=%s", BROWSE_API, BROWSE_PAGE, BROWSE_SORTS[sort].key)
	if page > 1 {
		fmt.sbprintf(&b, "&page=%d", page)
	}
	if q := strings.trim_space(text); q != "" {
		fmt.sbprintf(&b, "&q=%s", net.query_escape(q, context.temp_allocator))
	}
	return strings.to_string(b)
}

// --- the job -------------------------------------------------------------------

Browse_Kind :: enum {
	Search,
	Download,
}

// How a request ended. An answer that did not arrive and an answer that says
// nothing moved are different things, and only one of them replaces the list.
Browse_Answer :: enum {
	Failed,
	Fresh,
	Unchanged, // 304: what is on screen is still current
}

// One request in flight, and what came back. Cloned off the panel's buffers so
// they can go on being typed into.
Browse_Job :: struct {
	kind:      Browse_Kind,
	url:       string, // a search: the query. a download: the listing
	etag:      string, // what the last answer to this same URL carried
	slug:      string, // a download: the listing it belongs to

	answer:    Browse_Answer,
	message:   string,
	body:      string, // a search: the JSON. a download: the venue document
	etag_out:  string,
}

// The one request in flight, and the last search's answer. One per process:
// the panel shows one list and asks one question at a time.
Browser :: struct {
	worker:  ^thread.Thread,
	state:   Handoff_State,
	job:     Browse_Job,

	// Everything below belongs to the main thread and is kept between requests,
	// so the list stays on screen while the next question is in flight.
	results: Browse_Page,
	url:     string, // which query `results` and `etag` answer
	etag:    string,
	message: string,
	ok:      bool,
	asked:   bool,   // whether anything has been searched yet
	getting: string, // the slug being downloaded, "" for none
}

browse_busy :: proc(br: ^Browser) -> bool {
	return sync.atomic_load(&br.state) != .Idle
}

// Ask the site for a page of venues. The tag from the last answer to this same
// URL goes with it: an unchanged query then costs headers and no body.
browse_search :: proc(br: ^Browser, text: string, sort: Browse_Sort, page: int) {
	url := browse_url(text, sort, page)
	etag := br.url == url ? br.etag : ""
	browse_start(br, Browse_Job{
		kind = .Search,
		url  = strings.clone(url),
		etag = strings.clone(etag),
	})
}

// Fetch one venue document. `slug` names the listing, not the venue: the id the
// game installs under comes out of the document itself.
browse_download :: proc(br: ^Browser, slug: string) {
	started := browse_start(br, Browse_Job{
		kind = .Download,
		url  = fmt.aprintf("%s/venues/%s", BROWSE_API, slug),
		slug = strings.clone(slug),
	})
	if !started {
		return
	}
	delete(br.getting)
	br.getting = strings.clone(slug)
}

@(private = "file")
browse_start :: proc(br: ^Browser, job: Browse_Job) -> (started: bool) {
	if browse_busy(br) {
		job := job
		browse_job_free(&job) // refused, so the clones are still ours to free
		return false
	}
	browse_job_free(&br.job)
	br.job = job
	sync.atomic_store(&br.state, Handoff_State.Running)
	br.worker = thread.create(browse_worker)
	br.worker.data = br
	thread.start(br.worker)
	return true
}

// Collect a finished request. The job stays readable until the next one
// replaces it, which is what browse_claim reads the answer out of.
browse_tick :: proc(br: ^Browser) -> (finished: bool) {
	if sync.atomic_load(&br.state) != .Done {
		return false
	}
	thread.join(br.worker)
	thread.destroy(br.worker)
	br.worker = nil
	sync.atomic_store(&br.state, Handoff_State.Idle)
	return true
}

// Take a finished search's page as the one on screen, and the tag that answer
// carried as the one to ask with next time.
browse_keep :: proc(br: ^Browser) -> (msg: string, ok: bool) {
	browse_page_free(br)
	if uerr := json.unmarshal(transmute([]u8)br.job.body, &br.results); uerr != nil {
		browse_page_free(br)
		return "the site's answer was not a venue listing", false
	}
	delete(br.url)
	delete(br.etag)
	br.url, br.etag = br.job.url, br.job.etag_out
	br.job.url, br.job.etag_out = "", ""
	return "", true
}

// json.unmarshal clones every string it reads, so a page is freed field by
// field, the same way a venue is.
@(private = "file")
browse_page_free :: proc(br: ^Browser) {
	for v in br.results.venues {
		delete(v.slug)
		delete(v.venue_id)
		delete(v.title)
		delete(v.author)
		delete(v.page_url)
	}
	delete(br.results.venues)
	br.results = {}
}

browse_job_free :: proc(job: ^Browse_Job) {
	delete(job.url)
	delete(job.etag)
	delete(job.slug)
	delete(job.message)
	delete(job.body)
	delete(job.etag_out)
	job^ = {}
}

// Wait out any flight, so a quit mid-request still joins its thread.
browser_delete :: proc(br: ^Browser) {
	for sync.atomic_load(&br.state) == .Running {
		thread.yield()
	}
	browse_tick(br)
	browse_job_free(&br.job)
	browse_page_free(br)
	delete(br.url)
	delete(br.etag)
	delete(br.message)
	delete(br.getting)
	br^ = {}
}

// --- the requests --------------------------------------------------------------

@(private = "file")
browse_worker :: proc(t: ^thread.Thread) {
	br := (^Browser)(t.data)
	switch br.job.kind {
	case .Search:
		browse_search_run(&br.job)
	case .Download:
		browse_download_run(&br.job)
	}
	// This thread's own arena; the frame loop's free_all cannot reach it.
	free_all(context.temp_allocator)
	sync.atomic_store(&br.state, Handoff_State.Done)
}

// One page of listings. Runs on the worker: everything it reads belongs to the
// job and everything it writes is read back only after Done.
browse_search_run :: proc(job: ^Browse_Job) {
	res, err_msg, err := net.get(job.url, job.etag, allocator = context.temp_allocator)
	if err != .None {
		job.message = strings.clone(err_msg)
		return
	}
	if res.status == 304 {
		job.answer = .Unchanged
		return
	}
	if res.status >= 400 {
		job.message = fmt.aprintf("the site answered %d", res.status)
		return
	}
	job.answer = .Fresh
	job.body = strings.clone(res.body)
	job.etag_out = strings.clone(res.etag)
}

// One venue document, checked against the hash the site published for it.
browse_download_run :: proc(job: ^Browse_Job) {
	res, err_msg, err := net.get(job.url, allocator = context.temp_allocator)
	if err != .None {
		job.message = strings.clone(err_msg)
		return
	}
	detail: Browse_Detail
	parsed := json.unmarshal(
		transmute([]u8)res.body, &detail, json.DEFAULT_SPECIFICATION, context.temp_allocator,
	) == nil
	if !parsed || !detail.ok {
		reason := parsed && detail.error != "" ? detail.error : fmt.tprintf("answered %d", res.status)
		job.message = fmt.aprintf("the site would not describe %s: %s", job.slug, reason)
		return
	}
	if len(detail.venue.versions) == 0 {
		job.message = fmt.aprintf("%s has no published version", job.slug)
		return
	}
	// Newest first, and the newest is what the panel offered.
	newest := detail.venue.versions[0]

	blob, blob_msg, blob_err := net.get(newest.download_url, allocator = context.temp_allocator)
	if blob_err != .None {
		job.message = strings.clone(blob_msg)
		return
	}
	if blob.status >= 400 {
		job.message = fmt.aprintf("the download answered %d", blob.status)
		return
	}
	// The hash is the whole point of asking for the listing first. A file that
	// does not come out to it is not the venue that was published, whatever
	// went wrong between here and there.
	got := sha256_hex(transmute([]u8)blob.body, context.temp_allocator)
	if !strings.equal_fold(got, newest.sha256) {
		job.message = strings.clone("the file did not come out to the hash the site published for it")
		return
	}
	job.answer = .Fresh
	job.body = strings.clone(blob.body)
	job.message = fmt.aprintf("version %d", newest.version)
}

// The hash a download has to come out to, in the lower-case hex the site
// publishes it as.
sha256_hex :: proc(data: []u8, allocator := context.temp_allocator) -> string {
	digest: [sha2.DIGEST_SIZE_256]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, digest[:])
	return string(hex.encode(digest[:], allocator))
}

// --- what a download becomes ---------------------------------------------------

// The downloaded bytes, as a venue of ours in maps/.
//
// The venue arrives with the id it was published under, which is what says
// whether this is a venue we already have. Its name only has to be free: a
// name is a file here, a directory in the game and a localization key, and two
// venues cannot share one. Our own copy of this listing is the exception, and
// overwriting it is the point.
browse_install :: proc(
	vs: ^Install_Scan,
	slug: string,
	data: []u8,
) -> (
	name: string,
	msg: string,
	ok: bool,
) {
	p, parse_msg, parsed := venue_parse(data, "the download")
	if !parsed {
		return "", parse_msg, false
	}
	defer venue_free(p)
	name = strings.clone(p.name, context.temp_allocator)
	dir := venue_dir(p)

	// The copy we already hold of this same venue, whatever it is called now.
	held, _, have_held := venue_load(p.id, context.temp_allocator)
	if have_held {
		if !venue_is_copy_of(held, slug) {
			return name, fmt.tprintf(
				"you already have %s, and it did not come from this listing", held.name,
			), false
		}
	} else if msg, ok = venue_name_free(vs, p.name); !ok {
		return name, msg, false
	}
	if _, dir_ok := ensure_maps_dir(); !dir_ok {
		return name, fmt.tprintf("could not create %s", maps_dir()), false
	}

	// Where it came from, written into the document rather than remembered
	// beside it: a copy handed on is still not the copier's to publish.
	delete(p.source.site)
	delete(p.source.slug)
	p.source = {site = strings.clone(UPLOAD_SITE), slug = strings.clone(slug)}
	if msg, ok = venue_write(p, venue_path(dir)); !ok {
		return name, msg, false
	}
	// Renamed upstream since we last took it: the venue is the same one, so
	// the copy filed under the old name goes.
	if have_held && venue_dir(held) != dir {
		_ = os.remove(venue_file(held))
	}
	// The art is not in the file and never travels: the pack is rebuilt out of
	// whatever install this machine has. Built now, while a failure still means
	// "you do not have that game venue" rather than a broken export later.
	if _, pack_msg, pack_ok := content_pack_profile(vs, p.base); !pack_ok {
		_ = os.remove(venue_path(dir))
		return name, pack_msg, false
	}
	return name, "", true
}

// Whether this venue is our copy of that listing, and so an update rather than
// a collision. The panel asks it of a venue in the list; the install asks it of
// the file it is about to write over.
venue_is_copy_of :: proc(p: Venue, slug: string) -> bool {
	return p.source.site == UPLOAD_SITE && p.source.slug == slug
}


