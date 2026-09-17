package gfx

import "core:c"
import sdl "vendor:sdl3"
import vorbis "vendor:stb/vorbis"

Sound :: struct {
	stream: ^sdl.AudioStream,
	pcm:    [^]i16,
	bytes:  c.int,
	spec:   sdl.AudioSpec,
}

audio_ready: bool
master_volume: f32 = 1

InitAudioDevice :: proc() {
	if audio_ready { return }
	audio_ready = sdl.InitSubSystem(sdl.INIT_AUDIO)
}

CloseAudioDevice :: proc() {
	if !audio_ready { return }
	audio_ready = false
	sdl.QuitSubSystem(sdl.INIT_AUDIO)
}

IsAudioDeviceReady :: proc() -> bool { return audio_ready }
SetMasterVolume :: proc(volume: f32) { master_volume = clamp(volume, 0, 1) }

LoadSoundFromMemory :: proc(data: []u8) -> Sound {
	channels, rate: c.int
	pcm: [^]c.short
	frames := vorbis.decode_memory(raw_data(data), c.int(len(data)), &channels, &rate, &pcm)
	if frames <= 0 || pcm == nil { return {} }
	sound := Sound{
		pcm = cast([^]i16)pcm,
		bytes = frames * channels * size_of(i16),
		spec = {format = .S16, channels = channels, freq = rate},
	}
	if audio_ready {
		sound.stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &sound.spec, nil, nil)
		if sound.stream != nil { _ = sdl.SetAudioStreamGain(sound.stream, master_volume) }
	}
	return sound
}

UnloadSound :: proc(sound: Sound) {
	if sound.stream != nil { sdl.DestroyAudioStream(sound.stream) }
	if sound.pcm != nil { MemFree(sound.pcm) }
}

PlaySound :: proc(sound: Sound) {
	if sound.stream == nil || sound.pcm == nil { return }
	_ = sdl.ClearAudioStream(sound.stream)
	_ = sdl.SetAudioStreamGain(sound.stream, master_volume)
	_ = sdl.PutAudioStreamData(sound.stream, sound.pcm, sound.bytes)
	_ = sdl.FlushAudioStream(sound.stream)
	_ = sdl.ResumeAudioStreamDevice(sound.stream)
}

StopSound :: proc(sound: Sound) {
	if sound.stream != nil { _ = sdl.ClearAudioStream(sound.stream) }
}

IsSoundPlaying :: proc(sound: Sound) -> bool {
	return sound.stream != nil && sdl.GetAudioStreamQueued(sound.stream) > 0
}
