@tool
class_name MPFVideoPlayer
extends Control
## Renders a video player with options for end behaviour and events.
## Uses the GoZen native backend directly while preserving the MPF-facing API.

enum HideBehavior {
	## Stop playback when hidden and restart when visible
	RESTART,
	## Pause playback when hidden and resume when visible
	PAUSE,
	## Continue playback even when hidden
	CONTINUE,
}

enum EndBehavior {
	## No special behaviour after the video ends
	NOTHING,
	## Remove the parent MPFSlide (or MPFWidget) that holds this VideoPlayer
	REMOVE_SLIDE,
	## Call a custom method on this node
	CUSTOM_METHOD,
	## Call a custom method on the parent MPFSlide (or MPFWidget) that holds this VideoPlayer
	PARENT_METHOD,
}

enum ColorProfile {
	AUTO,
	BT470,
	BT601,
	BT709,
	BT2020,
	BT2100,
}

enum StreamType {
	VIDEO = 0,
	AUDIO = 1,
	SUBTITLE = 2,
}

signal finished
signal frame_changed(frame_nr: int)
signal next_frame_called(frame_nr: int)
signal video_loaded
signal video_ended
signal playback_started
signal playback_paused
signal playback_ready

const SHADER_PATH: String = "res://addons/mpf-gmc/yuv_to_rgb.gdshader"
const PLAYBACK_SPEED_MIN: float = 0.25
const PLAYBACK_SPEED_MAX: float = 4.0
const AUDIO_OFFSET_THRESHOLD: float = 0.1

## The action to take when this video node (or a parent) is hidden
@export var hide_behavior: HideBehavior = HideBehavior.RESTART
## The action to take after this video finishes playing.
@export var end_behavior: EndBehavior = EndBehavior.NOTHING
## An event (or comma-separated list of events) to be posted to MPF when the video finishes.
@export var events_when_stopped: String = ""
## The name of the method to call when the video finishes when end behaviour is a method.
@export var end_method: String = ""
## Ducking Settings
@export var ducking: DuckSettings
## If true, render the video in the editor
@export var preview_in_editor: bool = false

## Start playback automatically when shown.
@export var autoplay: bool = false

## Video file path.
@export_file("*.mp4", "*.mkv", "*.mov", "*.webm", "*.avi", "*.ogv")
var path: String = ""

@export_group("Playback")
## If true, decode and play the audio stream.
@export var enable_audio: bool = true
## Audio bus used for embedded video audio playback.
@export var audio_bus: String = "Master": set = set_audio_bus
## Gain applied to embedded video audio playback.
@export var volume_db: float = 0.0: set = set_volume_db
## If true, slightly adjusts audio speed to keep audio/video in sync.
@export var audio_speed_to_sync: bool = false
## Loop the video when it reaches the end.
@export var loop: bool = false
## Playback speed multiplier.
@export_range(PLAYBACK_SPEED_MIN, PLAYBACK_SPEED_MAX, 0.05, "or_less", "or_greater")
var playback_speed: float = 1.0: set = set_playback_speed
## Preserve original pitch when playback speed changes.
@export var pitch_adjust: bool = true: set = set_pitch_adjust

@export_group("Video")
## Override playback speed clamp range. Leave at (0, 0) to use default limits.
@export var playback_speed_override: Vector2 = Vector2.ZERO
## Force a specific colour profile, or leave AUTO to use the video metadata.
@export var color_profile: ColorProfile = ColorProfile.AUTO: set = _set_color_profile

@export_group("Debug")
## Print debug information about the system and loaded video.
@export var debug: bool = false

## Compatibility property preserved from the original MPFVideoPlayer.
var paused: bool = false:
	set(value):
		paused = value

		if Engine.is_editor_hint():
			if paused and is_open():
				pause()
			elif preview_in_editor and not paused and path != "":
				call_deferred("_refresh_editor_preview")
			return

		if paused:
			pause()
		elif is_open() and not _is_playing:
			play()

@warning_ignore("shadowed_global_identifier")
var log: GMCLogger

var video: GoZenVideo = null

var video_texture: TextureRect = TextureRect.new()
var audio_player: AudioStreamPlayer = AudioStreamPlayer.new()

var _is_playing: bool = false
var current_frame: int = 0: set = _set_current_frame

var video_streams: PackedInt32Array = []
var audio_streams: PackedInt32Array = []
var subtitle_streams: PackedInt32Array = []
var chapters: Array[Chapter] = []

var _time_elapsed: float = 0.0
var _frame_time: float = 0.0
var _skips: int = 0

var _rotation: int = 0
var _padding: int = 0
var _frame_rate: float = 0.0
var _frame_count: int = 0
var _has_alpha: bool = false

var _resolution: Vector2i = Vector2i.ZERO
var _shader_material: ShaderMaterial = null

var _video_thread: int = -1
var _audio_pitch_effect: AudioEffectPitchShift = AudioEffectPitchShift.new()
var _editor_refresh_queued: bool = false

var y_texture: ImageTexture
var u_texture: ImageTexture
var v_texture: ImageTexture
var a_texture: ImageTexture

func set_audio_bus(value: String) -> void:
	audio_bus = value
	if audio_player != null:
		audio_player.bus = value

func set_volume_db(value: float) -> void:
	volume_db = value
	if audio_player != null:
		audio_player.volume_db = value

func _enter_tree() -> void:
	var empty_image: Image = Image.create_empty(2, 2, false, Image.FORMAT_R8)

	y_texture = ImageTexture.create_from_image(empty_image)
	u_texture = ImageTexture.create_from_image(empty_image)
	v_texture = ImageTexture.create_from_image(empty_image)
	a_texture = ImageTexture.create_from_image(empty_image)

	if _shader_material == null:
		_shader_material = ShaderMaterial.new()
		_shader_material.shader = load(SHADER_PATH)

	var existing_video_texture: Node = get_node_or_null("VideoTexture")
	if existing_video_texture != null and existing_video_texture is TextureRect:
		video_texture = existing_video_texture as TextureRect
	else:
		video_texture = TextureRect.new()
		video_texture.name = "VideoTexture"
		add_child(video_texture)

	video_texture.material = _shader_material
	video_texture.texture = ImageTexture.new()
	video_texture.anchor_left = 0.0
	video_texture.anchor_top = 0.0
	video_texture.anchor_right = 1.0
	video_texture.anchor_bottom = 1.0
	video_texture.offset_left = 0.0
	video_texture.offset_top = 0.0
	video_texture.offset_right = 0.0
	video_texture.offset_bottom = 0.0
	video_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	video_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE

	var existing_audio_player: Node = get_node_or_null("AudioPlayer")
	if existing_audio_player != null and existing_audio_player is AudioStreamPlayer:
		audio_player = existing_audio_player as AudioStreamPlayer
	else:
		audio_player = AudioStreamPlayer.new()
		audio_player.name = "AudioPlayer"
		add_child(audio_player)

	audio_player.bus = audio_bus
	audio_player.volume_db = volume_db

	if AudioServer.get_bus_index(audio_player.bus) == -1:
		AudioServer.add_bus()
		audio_player.bus = AudioServer.get_bus_name(AudioServer.bus_count - 1)
		AudioServer.add_bus_effect(AudioServer.bus_count - 1, _audio_pitch_effect)

	if debug and OS.get_name().to_lower() != "web":
		_print_system_debug()

	if Engine.is_editor_hint():
		return

	log = preload("res://addons/mpf-gmc/scripts/log.gd").new("VideoPlayer<%s>" % name)

	if not is_visible_in_tree() and hide_behavior != HideBehavior.CONTINUE:
		stop()

func _exit_tree() -> void:
	if _video_thread != -1:
		var error: int = WorkerThreadPool.wait_for_task_completion(_video_thread)
		if error != OK:
			printerr("Something went wrong waiting for task completion! %s" % error)
		_video_thread = -1

	if video != null:
		close()

	if audio_player != null:
		var bus_index := AudioServer.get_bus_index(audio_player.bus)
		if bus_index > 0 and bus_index < AudioServer.bus_count:
			AudioServer.remove_bus(bus_index)

func _ready() -> void:
	playback_ready.emit()

	if Engine.is_editor_hint():
		if preview_in_editor and path != "":
			call_deferred("_refresh_editor_preview")
		return

	if path != "" and video == null:
		set_video_path(path)

	video_ended.connect(_on_finished)
	visibility_changed.connect(_on_visibility)

	if _is_playing and ducking:
		ducking.calculate_release_time(Time.get_ticks_msec())
		MPF.media.sound.buses[ducking.target_bus].duck(ducking)

func _notification(what: int) -> void:
	if Engine.is_editor_hint() and what == NOTIFICATION_VISIBILITY_CHANGED:
		if preview_in_editor:
			call_deferred("_refresh_editor_preview")

func _process(delta: float) -> void:
	if _is_playing:
		_skips = 1
		_time_elapsed += delta
		if _time_elapsed < _frame_time:
			return

		if _time_elapsed >= _frame_time:
			var frames: float = _time_elapsed / _frame_time
			_skips = int(frames)

		_time_elapsed -= _skips * _frame_time
		current_frame += _skips

		if current_frame >= _frame_count:
			_is_playing = false
			if enable_audio and audio_player.stream != null:
				audio_player.set_stream_paused(true)

			video_ended.emit()
			if loop:
				seek_frame(0)
				play()
		else:
			if enable_audio and audio_player.stream != null:
				_sync_audio_video()

			if _skips > _frame_rate:
				seek_frame(current_frame)
			else:
				while _skips != 1:
					next_frame(true)
					_skips -= 1
				next_frame()
	elif _video_thread != -1:
		var error: int = WorkerThreadPool.wait_for_task_completion(_video_thread)
		if error != OK:
			printerr("Something went wrong waiting for task completion! %s" % error)

		_video_thread = -1
		_update_video(video)

		if autoplay:
			play()

func _play() -> void:
	play()
	if ducking:
		ducking.calculate_release_time(Time.get_ticks_msec())
		ducking.bus.duck(ducking)

func _on_visibility() -> void:
	if Engine.is_editor_hint():
		return

	var do_show: bool = is_visible_in_tree() and autoplay and not Engine.is_editor_hint()
	if log:
		log.debug("Visibility change, visible is now %s", do_show)

	match hide_behavior:
		HideBehavior.RESTART:
			if do_show:
				_play()
			else:
				stop()

		HideBehavior.PAUSE:
			paused = not do_show
			if log:
				log.debug("Pause state set to %s", paused)
			if not paused and not _is_playing:
				_play()

		HideBehavior.CONTINUE:
			if do_show and not _is_playing:
				_play()

func _on_finished() -> void:
	finished.emit()

	if end_behavior == EndBehavior.REMOVE_SLIDE:
		_remove_self()
	elif end_behavior == EndBehavior.CUSTOM_METHOD:
		if end_method != "" and has_method(end_method):
			call(end_method)
	elif end_behavior == EndBehavior.PARENT_METHOD:
		var parent_node: Node = _get_mpf_parent()
		if parent_node != null and end_method != "" and parent_node.has_method(end_method):
			parent_node.call(end_method)

	if events_when_stopped:
		for e in events_when_stopped.split(","):
			var event_name := e.strip_edges()
			if event_name != "":
				MPF.server.send_event(event_name)

func _remove_self() -> void:
	var parent: Node = _get_mpf_parent()
	if parent == null:
		return

	var grandparent: Node = parent.get_parent()
	while grandparent != null:
		if parent is MPFSlide and grandparent is MPFDisplay:
			break
		elif parent is MPFWidget and grandparent is MPFSlide:
			break
		parent = grandparent
		grandparent = grandparent.get_parent()

	if grandparent != null and grandparent.has_method("action_remove"):
		grandparent.action_remove(parent)

func _get_mpf_parent() -> Node:
	var parent: Node = self
	while parent != null:
		if parent is MPFSlide or parent is MPFWidget:
			return parent
		parent = parent.get_parent()

	printerr("No parent slide or widget found?")
	return null

func set_video_path(new_path: String) -> void:
	if video != null:
		close()

	if not is_node_ready():
		await ready
	if get_tree() and get_tree().root and not get_tree().root.is_node_ready():
		await get_tree().root.ready

	audio_player.stream = null

	if new_path == "" or new_path.ends_with(".tscn"):
		path = new_path
		if Engine.is_editor_hint() and preview_in_editor:
			call_deferred("_refresh_editor_preview")
		return
	elif new_path.split(":")[0] == "uid":
		new_path = ResourceUID.get_id_path(ResourceUID.text_to_id(new_path))

	path = new_path

	if Engine.is_editor_hint():
		if preview_in_editor:
			call_deferred("_refresh_editor_preview")
		return

	video = GoZenVideo.new()
	if debug:
		video.enable_debug()
	else:
		video.disable_debug()

	_video_thread = WorkerThreadPool.add_task(_open_video)

	if enable_audio:
		_open_audio()

func update_video(video_instance: GoZenVideo, audio_stream: AudioStreamWAV = null) -> void:
	if video != null:
		close()

	path = video_instance.get_path()
	_update_video(video_instance)

	if audio_stream:
		audio_player.stream = audio_stream
	else:
		_open_audio()

func _update_video(new_video: GoZenVideo) -> void:
	video = new_video
	if not is_open():
		printerr("Video isn't open!")
		return

	var image: Image
	var rotation_radians: float = deg_to_rad(video.get_rotation())

	_is_playing = false
	current_frame = 0

	_padding = video.get_padding()
	_rotation = video.get_rotation()
	_frame_rate = video.get_framerate()
	_resolution = video.get_resolution()
	_frame_count = video.get_frame_count()
	_has_alpha = video.get_has_alpha()

	video_streams = video.get_streams(StreamType.VIDEO)
	audio_streams = video.get_streams(StreamType.AUDIO)
	subtitle_streams = video.get_streams(StreamType.SUBTITLE)

	chapters.clear()
	for i: int in range(video.get_chapter_count()):
		@warning_ignore("UNSAFE_CALL_ARGUMENT")
		var chapter: Chapter = Chapter.new(
			video.get_chapter_start(i),
			video.get_chapter_end(i),
			video.get_chapter_metadata(i).get("title", "")
		)
		chapters.append(chapter)

	if abs(_rotation) == 90:
		image = Image.create_empty(_resolution.y, _resolution.x, false, Image.FORMAT_R8)
	else:
		image = Image.create_empty(_resolution.x, _resolution.y, false, Image.FORMAT_R8)

	image.fill(Color.WHITE)

	if debug:
		_print_video_debug()

	@warning_ignore("UNSAFE_METHOD_ACCESS")
	video_texture.texture.set_image(image)

	_shader_material.set_shader_parameter("resolution", video.get_actual_resolution())
	_shader_material.set_shader_parameter("full_color", video.is_full_color_range())
	_shader_material.set_shader_parameter("interlaced", video.get_interlaced())
	_shader_material.set_shader_parameter("rotation", rotation_radians)
	_set_color_profile()

	y_texture.set_image(video.get_y_data())
	u_texture.set_image(video.get_u_data())
	v_texture.set_image(video.get_v_data())
	a_texture.set_image(video.get_a_data() if _has_alpha else image)

	_shader_material.set_shader_parameter("y_data", y_texture)
	_shader_material.set_shader_parameter("u_data", u_texture)
	_shader_material.set_shader_parameter("v_data", v_texture)
	_shader_material.set_shader_parameter("a_data", a_texture)

	set_playback_speed(playback_speed)
	video_loaded.emit()

func _set_color_profile(new_profile: ColorProfile = color_profile) -> void:
	if _shader_material == null:
		color_profile = new_profile
		return

	var color_data: Vector4
	var profile_str: String = "bt709"

	color_profile = new_profile

	if video != null and is_open():
		profile_str = video.get_color_profile()

	if new_profile != ColorProfile.AUTO:
		profile_str = str(ColorProfile.find_key(new_profile)).to_lower()

	match profile_str:
		"bt2020", "bt2100":
			color_data = Vector4(1.4746, 0.16455, 0.57135, 1.8814)
		"bt601", "bt470":
			color_data = Vector4(1.402, 0.344136, 0.714136, 1.772)
		_:
			color_data = Vector4(1.5748, 0.1873, 0.4681, 1.8556)

	_shader_material.set_shader_parameter("color_profile", color_data)

func seek_frame(new_frame_nr: int) -> void:
	if not is_open() and new_frame_nr == current_frame:
		return

	current_frame = clamp(new_frame_nr, 0, _frame_count)
	if video.seek_frame(current_frame):
		printerr("Couldn't seek frame!")
	else:
		_set_frame_image()

	if enable_audio and audio_player.stream and audio_player.stream.get_length() != 0:
		audio_player.set_stream_paused(false)
		audio_player.play(current_frame / _frame_rate)
		audio_player.set_stream_paused(not _is_playing)

func next_frame(skip: bool = false) -> void:
	if video.next_frame(skip) and not skip:
		_set_frame_image()
		next_frame_called.emit(current_frame)
	elif not skip:
		print("Something went wrong getting next frame!")

func close() -> void:
	if video != null:
		if _is_playing:
			pause()
		video = null

func play() -> void:
	if Engine.is_editor_hint():
		if path == "" or not FileAccess.file_exists(path):
			return

		if video == null:
			video = GoZenVideo.new()
			if debug:
				video.enable_debug()
			else:
				video.disable_debug()

			if video.open(path):
				printerr("Error opening video in editor preview!")
				video = null
				return

			_update_video(video)

		if not is_open():
			return

		_is_playing = true
		return

	if not is_open():
		print("The video on '%s' isn't open yet!" % path)
		return
	if _is_playing:
		return

	_is_playing = true

	if enable_audio and audio_player.stream and audio_player.stream.get_length() != 0:
		audio_player.set_stream_paused(false)
		audio_player.play((current_frame + 1) / _frame_rate)
		audio_player.set_stream_paused(not _is_playing)

	playback_started.emit()

func pause() -> void:
	_is_playing = false
	if enable_audio and audio_player.stream != null:
		audio_player.set_stream_paused(true)
	playback_paused.emit()

func stop() -> void:
	pause()
	if is_open():
		seek_frame(0)

func is_playing() -> bool:
	return _is_playing

func _sync_audio_video() -> void:
	if _time_elapsed < 1.20:
		return

	if enable_audio and audio_player.stream and audio_player.stream.get_length() != 0:
		var expected_time: float = (current_frame + 1) / _frame_rate
		var actual_time: float = audio_player.get_playback_position() + AudioServer.get_time_since_last_mix()
		var audio_offset: float = actual_time - expected_time

		if abs(audio_offset) > AUDIO_OFFSET_THRESHOLD:
			if debug:
				print("Audio Sync: time correction: ", audio_offset)
			audio_player.seek(expected_time)
			audio_player.pitch_scale = playback_speed
		elif audio_speed_to_sync:
			if is_zero_approx(audio_player.pitch_scale - playback_speed):
				if audio_offset > AUDIO_OFFSET_THRESHOLD / 2.0:
					audio_player.pitch_scale = playback_speed * 0.99
					if debug:
						print("Audio Sync: slow down")
				elif audio_offset < -AUDIO_OFFSET_THRESHOLD / 2.0:
					audio_player.pitch_scale = playback_speed * 1.01
					if debug:
						print("Audio Sync: speed up")
			else:
				if not (audio_player.pitch_scale > playback_speed) != not (audio_offset < 0):
					audio_player.pitch_scale = playback_speed
					if debug:
						print("Audio Sync: back to normal")

func get_video_frame_count() -> int:
	return _frame_count

func get_video_framerate() -> float:
	return _frame_rate

func get_video_length() -> int:
	return int(_frame_count / _frame_rate)

func get_video_length_float() -> float:
	return _frame_count / _frame_rate

func get_current_playback_position() -> int:
	return int(current_frame / _frame_rate)

func get_current_playback_position_float() -> float:
	return current_frame / _frame_rate

func get_video_rotation() -> int:
	return _rotation

func is_video_alpha() -> bool:
	return _has_alpha

func get_stream_title(stream: int) -> String:
	if not is_open():
		printerr("Video is not open!")
		return ""
	return video.get_stream_metadata(stream).get("title")

func get_stream_language(stream: int) -> String:
	if not is_open():
		printerr("Video is not open!")
		return ""
	return video.get_stream_metadata(stream).get("language")

func is_open() -> bool:
	return video != null and video.is_open()

func _set_current_frame(new_current_frame: int) -> void:
	current_frame = new_current_frame
	frame_changed.emit(current_frame)

func _set_frame_image() -> void:
	RenderingServer.texture_2d_update(y_texture.get_rid(), video.get_y_data(), 0)
	RenderingServer.texture_2d_update(u_texture.get_rid(), video.get_u_data(), 0)
	RenderingServer.texture_2d_update(v_texture.get_rid(), video.get_v_data(), 0)
	if _has_alpha:
		RenderingServer.texture_2d_update(a_texture.get_rid(), video.get_a_data(), 0)

func set_playback_speed(new_playback_value: float) -> void:
	if playback_speed_override == Vector2.ZERO:
		playback_speed = clampf(new_playback_value, 0.5, 2.0)
	else:
		playback_speed = clampf(new_playback_value, playback_speed_override.x, playback_speed_override.y)

	if _frame_rate > 0.0:
		_frame_time = (1.0 / _frame_rate) / playback_speed

	if enable_audio and audio_player.stream != null:
		audio_player.pitch_scale = playback_speed
		_set_pitch_adjust()
		if _is_playing and _frame_rate > 0.0:
			audio_player.play(current_frame * (1.0 / _frame_rate))

func set_pitch_adjust(new_pitch_value: bool) -> void:
	pitch_adjust = new_pitch_value
	_set_pitch_adjust()

func _set_pitch_adjust() -> void:
	if pitch_adjust:
		_audio_pitch_effect.pitch_scale = clamp(1.0 / playback_speed, 0.5, 2.0)
	elif _audio_pitch_effect.pitch_scale != 1.0:
		_audio_pitch_effect.pitch_scale = 1.0

func set_audio_stream(stream: int) -> void:
	if not is_open():
		printerr("Video is not open!")
		return

	if not stream in audio_streams:
		printerr("Invalid audio stream!")
		return

	if enable_audio:
		_open_audio(stream)
		if _is_playing and audio_player.stream and audio_player.stream.get_length() != 0:
			audio_player.set_stream_paused(false)
			audio_player.play(current_frame / _frame_rate)
			audio_player.set_stream_paused(not _is_playing)

func duration_to_formatted_string(duration_in_seconds: float) -> String:
	var hours: int = floori(duration_in_seconds / 3600.0)
	var minutes: int = floori(duration_in_seconds / 60.0) % 60
	var seconds: int = floori(duration_in_seconds) % 60

	if hours == 0:
		return "%02d:%02d" % [minutes, seconds]
	return "%02d:%02d:%02d" % [hours, minutes, seconds]

func _open_video() -> void:
	if video.open(path):
		printerr("Error opening video!")

func _open_audio(stream_id: int = -1) -> void:
	var stream: AudioStreamFFmpeg = AudioStreamFFmpeg.new()

	if stream.open(path, stream_id) != OK:
		printerr("Failed to open AudioStreamFFmpeg for: %s" % path)
		return

	audio_player.stream = stream

func _refresh_editor_preview() -> void:
	if not Engine.is_editor_hint():
		return
	if _editor_refresh_queued:
			return

	_editor_refresh_queued = true
	call_deferred("_refresh_editor_preview_deferred")

func _refresh_editor_preview_deferred() -> void:
	_editor_refresh_queued = false

	if not Engine.is_editor_hint():
		return
	if not is_inside_tree():
		return

	if path == "":
		if video != null:
			close()
		return

	if not preview_in_editor:
		if is_open():
			pause()
			seek_frame(0)
		return

	if not FileAccess.file_exists(path):
		push_warning("Preview video not found: %s" % path)
		return

	if video == null:
		video = GoZenVideo.new()
		if debug:
			video.enable_debug()
		else:
			video.disable_debug()

		if video.open(path):
			printerr("Error opening video in editor preview!")
			video = null
			return

		_update_video(video)

	if is_open():
		pause()
		seek_frame(0)
		play()

func _print_stream_info(streams: PackedInt32Array) -> void:
	for i: int in range(len(streams)):
		var metadata: Dictionary = video.get_stream_metadata(streams[i])
		var title: String = metadata.get("title")
		var language: String = metadata.get("language")

		if title == "":
			title = "Track " + str(i + 1)
		if language != "":
			title += " - %s" % language

		print("- %s" % title)

func _print_system_debug() -> void:
	print_rich("[b]System info")
	print("OS name: ", OS.get_name())
	print("Distro name: ", OS.get_distribution_name())
	print("OS version: ", OS.get_version())
	print_rich("Memory info:\n\t", OS.get_memory_info())
	print("CPU name: ", OS.get_processor_name())
	print("Threads count: ", OS.get_processor_count())

func _print_video_debug() -> void:
	print_rich("[b]Video debug info")
	print("Extension: ", path.get_extension())
	print("Resolution: ", _resolution)
	print("Actual resolution: ", video.get_actual_resolution())
	print("Pixel format: ", video.get_pixel_format())
	print("Color profile: ", video.get_color_profile())
	print("Framerate: ", _frame_rate)
	print("Duration (in frames): ", _frame_count)
	print("Padding: ", _padding)
	print("Rotation: ", _rotation)
	print("Alpha: ", _has_alpha)
	print("Full color range: ", video.is_full_color_range())
	print("Interlaced flag: ", video.get_interlaced())
	print("Using sws: ", video.is_using_sws())
	print("Sar: ", video.get_sar())

	print_rich("Video streams: [i](%s)" % video_streams.size())
	_print_stream_info(video_streams)

	if audio_streams.size() != 0:
		print_rich("Audio streams: [i](%s)" % audio_streams.size())
		_print_stream_info(audio_streams)
	elif debug:
		print("No audio streams found.")

	if subtitle_streams.size() != 0:
		print_rich("Subtitle streams: [i](%s)" % subtitle_streams.size())
		_print_stream_info(subtitle_streams)
	elif debug:
		print("No subtitle streams found.")

	if chapters.size() != 0:
		print_rich("Chapters: [i](%s)" % chapters.size())
		for i: int in range(chapters.size()):
			var title: String = chapters[i].title
			if title == "":
				title = "Chapter " + str(i + 1)
			print("- %s-%s - %s" % [
				duration_to_formatted_string(chapters[i].start),
				duration_to_formatted_string(chapters[i].end),
				title
			])
	else:
		print("No chapters found.")

class Chapter:
	var start: float
	var end: float
	var title: String

	func _init(_start: float, _end: float, _title: String) -> void:
		start = _start
		end = _end
		title = _title
