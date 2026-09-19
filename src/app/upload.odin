package main

// Publishing a venue to dirtbench.paths.place.
//
// The site takes one multipart POST: the maps/<id>.json bytes, a username and
// password, the listing text, and optionally an image. It measures the stage
// count and the distances out of the document itself, so nothing here reports a
// figure the server would have to take on trust.
//
// Two different facts about a venue live in two different places, on purpose:
//
//   which listing it is    a claim about this account on this machine, so it is
//                          remembered in dirtbench.conf and never in the file.
//                          Without it an upload makes a second listing instead
//                          of a new version.
//   where it came from     Venue_Source, part of the document, because it has
//                          to travel with a copy. A downloaded venue is not
//                          ours to publish, and the panel refuses while it is
//                          set.
//
// The request runs on a thread of its own. It is one POST, but it is one POST
// over somebody's home connection, and the project manager goes on drawing.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "../net"

UPLOAD_HOST :: "dirtbench.paths.place"

UPLOAD_SITE :: "https://" + UPLOAD_HOST

UPLOAD_API :: UPLOAD_SITE + "/api/upload.php"

// The username is remembered, the password never is.
UPLOAD_USER_KEY :: "dirtbench_user"

// One per venue: `upload_slug.<id> = <slug>`.
UPLOAD_SLUG_PREFIX :: "upload_slug."

// --- what is remembered --------------------------------------------------------

upload_user :: proc(allocator := context.temp_allocator) -> string {
	user, _ := conf_get(UPLOAD_USER_KEY, allocator)
	return user
}

upload_user_remember :: proc(user: string) {
	if strings.trim_space(user) != "" {
		conf_set(UPLOAD_USER_KEY, strings.trim_space(user))
	}
}

@(private = "file")
slug_key :: proc(venue_id: string) -> string {
	return fmt.tprintf("%s%s", UPLOAD_SLUG_PREFIX, venue_id)
}

// The listing this venue was last published to, or "" for one that never was.
upload_slug :: proc(venue_id: string, allocator := context.temp_allocator) -> string {
	slug, _ := conf_get(slug_key(venue_id), allocator)
	return slug
}

upload_slug_remember :: proc(venue_id, slug: string) {
	conf_set(slug_key(venue_id), slug)
}

// Forget which listing a venue belongs to, so the next upload makes a new one
// rather than posting a version of a listing this venue is no longer tied to.
upload_slug_forget :: proc(venue_id: string) {
	conf_unset(slug_key(venue_id))
}

// --- the job -------------------------------------------------------------------

// Everything the request needs, cloned off the panel's buffers so they can go
// on being typed into while it is in flight, and everything that came back.
Upload_Job :: struct {
	username:    string,
	password:    string,
	title:       string,
	description: string,
	changelog:   string,
	slug:        string, // "" makes a new listing; set posts a new version
	level_path:  string,
	image_path:  string, // "" sends no image
	// Whether the image is ours to delete afterwards. A rendered thumbnail is;
	// a file the user pointed at is not.
	image_ours:  bool,

	ok:          bool,
	message:     string,
	slug_out:    string,
	url_out:     string,
}

// The one upload in flight, if any. One per process: a second would be racing
// the first for the same account's rate limit. See handoff.odin for the rule
// `state` enforces.
Uploader :: struct {
	worker: ^thread.Thread,
	state:  Handoff_State,
	venue:  string, // whose upload this is, for the row that shows it
	job:    Upload_Job,
}

upload_busy :: proc(up: ^Uploader) -> bool {
	return sync.atomic_load(&up.state) != .Idle
}

// Hand the job over. The caller has already filled it in; from here until
// upload_tick reports Done, nothing on the main thread may touch it.
upload_start :: proc(up: ^Uploader, venue_id: string, job: Upload_Job) {
	if upload_busy(up) {
		job := job
		upload_job_free(&job) // refused, so the clones are still ours to free
		return
	}
	upload_job_free(&up.job)
	delete(up.venue)
	up.venue = strings.clone(venue_id)
	up.job = job
	sync.atomic_store(&up.state, Handoff_State.Running)
	up.worker = thread.create(upload_worker)
	up.worker.data = up
	thread.start(up.worker)
}

// Collect a finished upload, or report that there is nothing to collect. The
// job stays readable until the next upload_start replaces it, which is what the
// panel shows the result out of.
upload_tick :: proc(up: ^Uploader) -> (finished: bool) {
	if sync.atomic_load(&up.state) != .Done {
		return false
	}
	thread.join(up.worker)
	thread.destroy(up.worker)
	up.worker = nil
	if up.job.image_ours && up.job.image_path != "" {
		os.remove(up.job.image_path)
	}
	// The password is gone the moment it is no longer needed. Nothing else in
	// the process keeps one.
	upload_password_forget(&up.job)
	sync.atomic_store(&up.state, Handoff_State.Idle)
	return true
}

// Wipe the password and let it go. Called the moment the request that needed it
// has finished, and again by upload_job_free, which is why it has to be safe to
// call twice.
@(private = "file")
upload_password_forget :: proc(job: ^Upload_Job) {
	if len(job.password) == 0 {
		job.password = ""
		return
	}
	mem.zero_slice(transmute([]u8)job.password)
	delete(job.password)
	job.password = ""
}

upload_job_free :: proc(job: ^Upload_Job) {
	delete(job.username)
	upload_password_forget(job)
	delete(job.title)
	delete(job.description)
	delete(job.changelog)
	delete(job.slug)
	delete(job.level_path)
	delete(job.image_path)
	delete(job.message)
	delete(job.slug_out)
	delete(job.url_out)
	job^ = {}
}

// Wait out any flight and collect it through upload_tick, so a quit mid-upload
// still removes the rendered temp image and wipes the password.
uploader_delete :: proc(up: ^Uploader) {
	for sync.atomic_load(&up.state) == .Running {
		thread.yield()
	}
	upload_tick(up)
	upload_job_free(&up.job)
	delete(up.venue)
	up^ = {}
}

// --- the request ---------------------------------------------------------------

@(private = "file")
upload_worker :: proc(t: ^thread.Thread) {
	up := (^Uploader)(t.data)
	upload_run(&up.job)
	// This thread's own arena; the frame loop's free_all cannot reach it.
	free_all(context.temp_allocator)
	sync.atomic_store(&up.state, Handoff_State.Done)
}

// What the server answers with, on success and on failure alike. Unknown keys
// are ignored, so the site may add fields without this having to know.
@(private = "file")
Upload_Reply :: struct {
	ok:      bool,
	error:   string,
	slug:    string,
	version: int,
	url:     string,
}

// The POST, and what to say about it. Runs on the worker: everything it reads
// belongs to the job and everything it writes is read back only after Done.
upload_run :: proc(job: ^Upload_Job) {
	fields := upload_fields(job^, context.temp_allocator)
	res, err_msg, err := net.post_form(UPLOAD_API, fields, allocator = context.temp_allocator)
	if err != .None {
		job.ok = false
		job.message = strings.clone(err_msg)
		return
	}

	reply: Upload_Reply
	parsed := json.unmarshal(
		transmute([]u8)res.body, &reply, json.DEFAULT_SPECIFICATION, context.temp_allocator,
	) == nil
	if !parsed {
		// A reply that is not JSON is the web server talking, not the site.
		job.ok = false
		job.message = fmt.aprintf("the site answered %d, and not in JSON", res.status)
		return
	}
	if !reply.ok || res.status >= 400 {
		job.ok = false
		reason := reply.error != "" ? reply.error : "no reason given"
		job.message = fmt.aprintf("the site refused it: %s", reason)
		return
	}
	job.ok = true
	job.slug_out = strings.clone(reply.slug)
	job.url_out = fmt.aprintf("%s/venue/%s", UPLOAD_SITE, reply.slug)
	job.message = fmt.aprintf("published as version %d", reply.version)
}

// The form the site is sent, and the whole contract with it.
//
// An empty slug is left out rather than sent empty: the endpoint reads a
// present slug as "a new version of that listing", and a listing nobody owns
// answers 404. The stage count and the distances are not here at all — the
// server measures those out of the document it is being handed.
upload_fields :: proc(job: Upload_Job, allocator := context.temp_allocator) -> []net.Form_Field {
	fields := make([dynamic]net.Form_Field, 0, 10, allocator)
	append(&fields, net.Form_Field{name = "username", value = job.username})
	append(&fields, net.Form_Field{name = "password", value = job.password})
	append(&fields, net.Form_Field{name = "title", value = job.title})
	append(&fields, net.Form_Field{name = "description", value = job.description})
	append(&fields, net.Form_Field{name = "changelog", value = job.changelog})
	if job.slug != "" {
		append(&fields, net.Form_Field{name = "slug", value = job.slug})
	}
	append(&fields, net.Form_Field{
		name     = "level",
		path     = job.level_path,
		filename = filepath.base(job.level_path),
		mime     = "application/json",
	})
	if job.image_path != "" {
		append(&fields, net.Form_Field{
			name     = "image",
			path     = job.image_path,
			filename = filepath.base(job.image_path),
			mime     = upload_image_mime(job.image_path),
		})
	}
	return fields[:]
}

// What the server is told an override image is. It sniffs the bytes anyway and
// re-encodes what it finds, so this only has to be honest, not exhaustive.
upload_image_mime :: proc(path: string) -> string {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".webp":
		return "image/webp"
	case ".bmp":
		return "image/bmp"
	}
	return ""
}
