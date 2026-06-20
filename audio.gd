extends Node
## Synthesizes all game audio at runtime (no external files): an ambient drone,
## a proximity heartbeat, a chase growl, plus one-shot stinger and pickup blip.

const RATE := 22050

var _drone: AudioStreamPlayer
var _growl: AudioStreamPlayer
var _heart: AudioStreamPlayer
var _stinger: AudioStreamPlayer
var _blip: AudioStreamPlayer

var _hb_accum := 0.0

func _ready() -> void:
	_drone = _make_player(_make_drone(), true, -16.0)
	_growl = _make_player(_make_growl(), true, -60.0)
	_heart = _make_player(_make_thump(), false, -10.0)
	_stinger = _make_player(_make_stinger(), false, -3.0)
	_blip = _make_player(_make_blip(), false, -10.0)
	_drone.play()
	_growl.play()

func _make_player(stream: AudioStream, looping: bool, vol_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = vol_db
	add_child(p)
	return p

## Called each frame by the world with monster distance + chase state.
func update(dist: float, chasing: bool, delta: float) -> void:
	# Heartbeat: faster and louder the closer the monster gets (within range).
	if dist < 16.0:
		var closeness := 1.0 - dist / 16.0
		_heart.volume_db = lerpf(-22.0, -5.0, closeness)
		_hb_accum -= delta
		if _hb_accum <= 0.0:
			_hb_accum = lerpf(1.1, 0.34, closeness)
			_heart.play()
	# Chase growl swells while it's actively hunting and near.
	var target := -60.0
	if chasing:
		target = lerpf(-26.0, -6.0, clampf(1.0 - dist / 18.0, 0.0, 1.0))
	_growl.volume_db = lerpf(_growl.volume_db, target, clampf(delta * 4.0, 0.0, 1.0))

func play_stinger() -> void:
	_stinger.play()

func play_blip() -> void:
	_blip.play()

# --- Synthesis --------------------------------------------------------------

func _make_wav(samples: PackedFloat32Array, looping: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	if looping:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = samples.size()
	return wav

func _make_drone() -> AudioStreamWAV:
	var n := RATE * 4
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var v := 0.18 * sin(TAU * 55.0 * t) + 0.12 * sin(TAU * 58.75 * t) + 0.06 * sin(TAU * 36.0 * t)
		v += 0.02 * (randf() * 2.0 - 1.0)
		v *= 0.8 + 0.2 * sin(TAU * 0.25 * t)
		s[i] = v * 0.5
	return _make_wav(s, true)

func _make_growl() -> AudioStreamWAV:
	var n := RATE * 3
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var v := 0.2 * sin(TAU * 70.0 * t) + 0.16 * sin(TAU * 73.5 * t) + 0.1 * sin(TAU * 110.0 * t)
		v += 0.08 * (randf() * 2.0 - 1.0)
		v *= 0.7 + 0.3 * sin(TAU * 6.0 * t)
		s[i] = v * 0.6
	return _make_wav(s, true)

func _make_thump() -> AudioStreamWAV:
	var n := int(RATE * 0.32)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var env := exp(-t * 16.0)
		var freq := 62.0 - 24.0 * t
		s[i] = sin(TAU * freq * t) * env * 0.95
	return _make_wav(s, false)

func _make_stinger() -> AudioStreamWAV:
	var n := int(RATE * 1.3)
	var s := PackedFloat32Array()
	s.resize(n)
	var freqs := [196.0, 233.0, 311.0, 415.0, 466.0]
	for i in n:
		var t := float(i) / RATE
		var env := exp(-t * 3.5)
		var v := 0.0
		for f in freqs:
			v += sin(TAU * f * t)
		v /= freqs.size()
		v += 0.5 * (randf() * 2.0 - 1.0) * exp(-t * 30.0)
		s[i] = v * env * 0.9
	return _make_wav(s, false)

func _make_blip() -> AudioStreamWAV:
	var n := int(RATE * 0.22)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var env := exp(-t * 8.0)
		var freq := 660.0 + 440.0 * t
		s[i] = sin(TAU * freq * t) * env * 0.5
	return _make_wav(s, false)
