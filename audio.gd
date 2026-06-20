extends Node
## Synthesizes all game audio at runtime (no external files): an ambient drone,
## a proximity heartbeat, a chase growl, plus one-shot stinger and pickup blip.

const RATE := 22050

var _drone: AudioStreamPlayer
var _growl: AudioStreamPlayer
var _heart: AudioStreamPlayer
var _stinger: AudioStreamPlayer
var _blip: AudioStreamPlayer
var _screech: AudioStreamPlayer
var _foot: AudioStreamPlayer

var _hb_accum := 0.0
var _step_accum := 0.0

func _ready() -> void:
	_drone = _make_player(_make_drone(), true, -11.0)
	_growl = _make_player(_make_growl(), true, -55.0)
	_heart = _make_player(_make_thump(), false, -6.0)
	_stinger = _make_player(_make_stinger(), false, 1.0)
	_blip = _make_player(_make_blip(), false, -5.0)
	_screech = _make_player(_make_screech(), false, -1.0)
	_foot = _make_player(_make_footstep(), false, -6.0)
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
		_heart.volume_db = lerpf(-15.0, 2.0, closeness)
		_hb_accum -= delta
		if _hb_accum <= 0.0:
			_hb_accum = lerpf(1.1, 0.34, closeness)
			_heart.play()
	# Chase growl swells while it's actively hunting and near.
	var target := -55.0
	if chasing:
		target = lerpf(-20.0, 0.0, clampf(1.0 - dist / 18.0, 0.0, 1.0))
	_growl.volume_db = lerpf(_growl.volume_db, target, clampf(delta * 4.0, 0.0, 1.0))

	# Pounding footsteps while it chases — faster and louder as it nears.
	if chasing and dist < 16.0:
		var close := clampf(1.0 - dist / 16.0, 0.0, 1.0)
		_foot.volume_db = lerpf(-14.0, 3.0, close)
		_step_accum -= delta
		if _step_accum <= 0.0:
			_step_accum = lerpf(0.46, 0.24, close)
			_foot.play()

func play_stinger() -> void:
	_stinger.play()

func play_blip() -> void:
	_blip.play()

func play_spotted() -> void:
	_screech.play()

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
		var low := 0.22 * sin(TAU * 62.0 * t) + 0.16 * sin(TAU * 67.0 * t)
		var snarl := 0.13 * sin(TAU * 175.0 * t + 3.0 * sin(TAU * 7.0 * t))  # FM snarl
		var v := low + snarl
		v += 0.12 * (randf() * 2.0 - 1.0)
		v *= 0.6 + 0.4 * sin(TAU * 8.0 * t)   # rough, breathing tremor
		s[i] = v * 0.65
	return _make_wav(s, true)

## A heavy stomp: low thud + a noisy scuff.
func _make_footstep() -> AudioStreamWAV:
	var n := int(RATE * 0.18)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var thud := sin(TAU * 90.0 * t) * exp(-t * 22.0)
		var scuff := (randf() * 2.0 - 1.0) * exp(-t * 40.0) * 0.6
		s[i] = (thud * 0.8 + scuff) * 0.8
	return _make_wav(s, false)

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

## A sharp warbling screech for the moment the monster locks onto you.
func _make_screech() -> AudioStreamWAV:
	var n := int(RATE * 0.6)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var env := sin(PI * clampf(t / 0.6, 0.0, 1.0))
		var sweep := 700.0 + 800.0 * sin(TAU * 3.5 * t)
		var v := 0.5 * sin(TAU * sweep * t) + 0.3 * sin(TAU * sweep * 1.5 * t)
		v += 0.3 * (randf() * 2.0 - 1.0)
		s[i] = v * env * 0.7
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
