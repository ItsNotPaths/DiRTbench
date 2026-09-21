package main

// Pace-note playback: loading the recorded clips, and riding the stage with the
// co-driver calling. Split from geo/pacenote.odin, which generates the notes and
// knows nothing about the editor, the filesystem or SDL audio.

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../gfx"
import "../geo"

// Decode every clip in the `pacenotes` directory beside the binary into a map
// keyed by basename.
// Keys are cloned (persistent); pace_audio_unload frees them.
//
// The clips are read at startup, not embedded: they are someone else's
// recordings and a release must be able to ship without them. An empty map is
// an ordinary state — every caller already asks before it plays.
pace_audio_load :: proc() -> map[string]gfx.Sound {
	clips := make(map[string]gfx.Sound)
	dir := pacenotes_dir()
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return clips
	}
	for info in infos {
		if info.type != .Regular || filepath.ext(info.name) != ".ogg" {
			continue
		}
		path, _ := filepath.join({dir, info.name}, context.temp_allocator)
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil {
			continue
		}
		stem := strings.trim_suffix(info.name, ".ogg")
		clips[strings.clone(stem)] = gfx.LoadSoundFromMemory(data)
	}
	return clips
}

pace_audio_unload :: proc(clips: ^map[string]gfx.Sound) {
	for name, snd in clips {
		gfx.UnloadSound(snd)
		delete(name)
	}
	delete(clips^)
}

// Position and travel direction on the centreline at arc length `s` (linear
// between samples). `fwd` is the segment direction the cursor is on — it drives
// the chase camera's heading.
@(private = "file")
pace_ride_pos :: proc(ribbon: []geo.Cross_Section, arc: []f32, s: f32) -> (pos, fwd: gfx.Vector3) {
	n := len(ribbon)
	if n == 0 {
		return
	}
	if n == 1 {
		return ribbon[0].pos, ribbon[0].fwd
	}
	if s <= 0 {
		return ribbon[0].pos, gfx.Vector3Normalize(ribbon[1].pos - ribbon[0].pos)
	}
	for i in 1 ..< n {
		if arc[i] >= s {
			seg := ribbon[i].pos - ribbon[i - 1].pos
			t := (s - arc[i - 1]) / max(arc[i] - arc[i - 1], 1e-6)
			return ribbon[i - 1].pos + seg * t, gfx.Vector3Normalize(seg)
		}
	}
	return ribbon[n - 1].pos, gfx.Vector3Normalize(ribbon[n - 1].pos - ribbon[n - 2].pos)
}

// End the ride and silence whatever is mid-phrase. One audio device per
// process, so the window that started a ride is the one that hands it back —
// closing that window counts as stopping (see editor_close).
preview_stop :: proc(ed: ^Editor) {
	ed.previewing = false
	if ed.app.play_i < len(ed.app.play_q) {
		gfx.StopSound(ed.app.play_q[ed.app.play_i])
	}
	clear(&ed.app.play_q)
	ed.app.play_i = 0
	ed.app.play_started = false
}

// Start/stop the ride from the head of the compiled stage.
preview_toggle :: proc(ed: ^Editor) {
	was_riding := ed.previewing
	preview_stop(ed)
	if was_riding {
		return
	}
	ed.previewing = true
	ed.preview_s = 0
	ed.preview_next = 0
	ed.preview_last = -1
	// Snap the camera to the start heading so the ride opens looking down the
	// stage, rather than easing in from the last orbit angle.
	if len(ed.stage.ribbon) >= 2 {
		f := gfx.Vector3Normalize(ed.stage.ribbon[1].pos - ed.stage.ribbon[0].pos)
		if abs(f.x) + abs(f.z) > 1e-5 {
			ed.cam.yaw = math.atan2(-f.x, -f.z)
		}
		ed.cam.target = ed.stage.ribbon[0].pos
	}
}

@(private = "file")
pace_enqueue :: proc(ed: ^Editor, nt: geo.Pace_Note) {
	for name in geo.pace_tile(geo.pace_note_tokens(nt), ed.app.clips) {
		if snd, ok := ed.app.clips[name]; ok {
			append(&ed.app.play_q, snd)
		}
	}
}

// Play the queued clips one after another: start the head, advance when it ends.
@(private = "file")
pace_pump_queue :: proc(ed: ^Editor) {
	if ed.app.play_i >= len(ed.app.play_q) {
		if len(ed.app.play_q) > 0 {
			clear(&ed.app.play_q)
			ed.app.play_i = 0
			ed.app.play_started = false
		}
		return
	}
	cur := ed.app.play_q[ed.app.play_i]
	if !ed.app.play_started {
		gfx.PlaySound(cur)
		ed.app.play_started = true
	} else if !gfx.IsSoundPlaying(cur) {
		ed.app.play_i += 1
		ed.app.play_started = false
	}
}

// Advance the ride and fire notes. Call once per frame; the queue is pumped even
// when not riding, so a phrase in flight finishes cleanly after Stop.
preview_update :: proc(ed: ^Editor) {
	pace_pump_queue(ed)
	if !ed.previewing {
		return
	}
	if len(ed.stage.ribbon) < 2 {
		ed.previewing = false
		return
	}
	arc := geo.ribbon_arc(ed.stage.ribbon)
	total := arc[len(arc) - 1]
	ed.preview_s += ed.preview_speed * gfx.GetFrameTime()
	for ed.preview_next < len(ed.stage.notes) && ed.stage.notes[ed.preview_next].station <= ed.preview_s {
		pace_enqueue(ed, ed.stage.notes[ed.preview_next])
		ed.preview_last = ed.preview_next
		ed.preview_next += 1
	}
	pos, fwd := pace_ride_pos(ed.stage.ribbon, arc, ed.preview_s)
	ed.preview_pos = pos
	// Attach the camera to the ride: target rides the car, and the yaw swings to
	// look down the stage (eye behind the car, facing travel). Pitch and zoom stay
	// the user's. Yaw is eased toward the heading so corners don't snap. The
	// caller builds cam3d after this has run.
	ed.cam.target = pos
	fh := gfx.Vector3{fwd.x, 0, fwd.z}
	if gfx.Vector3Length(fh) > 1e-5 {
		target_yaw := math.atan2(-fh.x, -fh.z)
		d := target_yaw - ed.cam.yaw
		for d > math.PI {d -= 2 * math.PI}
		for d < -math.PI {d += 2 * math.PI}
		ed.cam.yaw += d * min(1, 6 * gfx.GetFrameTime())
	}
	if ed.preview_s > total + 5 {
		ed.previewing = false // ran off the end
	}
}
