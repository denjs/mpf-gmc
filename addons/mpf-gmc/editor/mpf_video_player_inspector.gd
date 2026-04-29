@tool
extends EditorInspectorPlugin

const PLAYER_SCRIPT: Script = preload("res://addons/mpf-gmc/classes/mpf_video_player.gd")

var host_editor_plugin

class VideoPreviewControls:
	extends VBoxContainer

	var player
	var editor_plugin
	var transport: HBoxContainer
	var range_actions: HBoxContainer
	var play_pause_button: Button
	var step_back_button: Button
	var step_forward_button: Button
	var set_start_button: Button
	var set_end_button: Button
	var slider: HSlider
	var status_label: Label
	var update_timer: Timer
	var _is_scrubbing: bool = false

	func _init(target_player, target_editor_plugin) -> void:
		player = target_player
		editor_plugin = target_editor_plugin

	func _ready() -> void:
		size_flags_horizontal = Control.SIZE_EXPAND_FILL

		transport = HBoxContainer.new()
		add_child(transport)

		step_back_button = Button.new()
		step_back_button.text = "<"
		step_back_button.tooltip_text = "Step back one frame"
		step_back_button.pressed.connect(_on_step_back_pressed)
		transport.add_child(step_back_button)

		play_pause_button = Button.new()
		play_pause_button.text = "Play"
		play_pause_button.tooltip_text = "Play or pause the editor preview"
		play_pause_button.pressed.connect(_on_play_pause_pressed)
		transport.add_child(play_pause_button)

		step_forward_button = Button.new()
		step_forward_button.text = ">"
		step_forward_button.tooltip_text = "Step forward one frame"
		step_forward_button.pressed.connect(_on_step_forward_pressed)
		transport.add_child(step_forward_button)

		range_actions = HBoxContainer.new()
		add_child(range_actions)

		set_start_button = Button.new()
		set_start_button.text = "Set Start"
		set_start_button.tooltip_text = "Use the current preview position as the runtime start position"
		set_start_button.pressed.connect(_on_set_start_pressed)
		range_actions.add_child(set_start_button)

		set_end_button = Button.new()
		set_end_button.text = "Set End"
		set_end_button.tooltip_text = "Use the current preview position as the runtime end position"
		set_end_button.pressed.connect(_on_set_end_pressed)
		range_actions.add_child(set_end_button)

		slider = HSlider.new()
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.step = 0.001
		slider.min_value = 0.0
		slider.drag_started.connect(_on_slider_drag_started)
		slider.drag_ended.connect(_on_slider_drag_ended)
		slider.value_changed.connect(_on_slider_value_changed)
		add_child(slider)

		status_label = Label.new()
		add_child(status_label)

		update_timer = Timer.new()
		update_timer.wait_time = 0.1
		update_timer.autostart = true
		update_timer.timeout.connect(_refresh)
		add_child(update_timer)

		_refresh()

	func _refresh() -> void:
		if not is_instance_valid(player):
			return

		var has_preview: bool = _prepare_preview_if_possible()
		step_back_button.disabled = not has_preview
		step_forward_button.disabled = not has_preview
		set_start_button.disabled = not has_preview
		set_end_button.disabled = not has_preview
		slider.editable = has_preview
		play_pause_button.disabled = not has_preview
		play_pause_button.text = "Pause" if has_preview and player.is_playing() else "Play"

		if not has_preview:
			slider.max_value = 0.0
			if not _is_scrubbing:
				slider.value = 0.0
			status_label.text = "Enable preview and assign a valid video path to scrub."
			return

		var duration: float = maxf(player.get_video_length_float(), 0.0)
		var position: float = clampf(player.get_current_playback_position_float(), 0.0, duration)
		slider.max_value = duration
		if not _is_scrubbing:
			slider.value = position
		status_label.text = "%s / %s" % [
			player.duration_to_formatted_string(position),
			player.duration_to_formatted_string(duration)
		]
		status_label.text += "    Start: %s    End: %s" % [
			player.duration_to_formatted_string(player.start_position_seconds),
			"Video End" if player.end_position_seconds < 0.0 else player.duration_to_formatted_string(player.end_position_seconds)
		]

	func _prepare_preview_if_possible() -> bool:
		if not player.preview_in_editor:
			return false
		if player.path == "":
			return false
		if not player.is_inside_tree() or not player.is_node_ready():
			return false
		if not player.has_method("_ensure_editor_preview_video"):
			return false
		return bool(player.call("_ensure_editor_preview_video"))

	func _seek_to_seconds(seconds: float) -> void:
		if not _prepare_preview_if_possible():
			return
		var frame_rate: float = player.get_video_framerate()
		if frame_rate <= 0.0:
			return
		player.seek_frame(int(round(seconds * frame_rate)))
		_refresh()

	func _step_frames(frame_delta: int) -> void:
		if not _prepare_preview_if_possible():
			return
		player.pause()
		player.seek_frame(player.current_frame + frame_delta)
		_refresh()

	func _on_play_pause_pressed() -> void:
		if not _prepare_preview_if_possible():
			return
		if player.is_playing():
			player.pause()
		else:
			player.play()
		_refresh()

	func _on_step_back_pressed() -> void:
		_step_frames(-1)

	func _on_step_forward_pressed() -> void:
		_step_frames(1)

	func _on_set_start_pressed() -> void:
		if not _prepare_preview_if_possible():
			return
		var undo_redo = editor_plugin.get_undo_redo()
		var old_start_frame: int = player.start_frame
		var old_start_seconds: float = player.start_position_seconds
		var new_start_frame: int = player.current_frame
		var new_start_seconds: float = player.get_current_playback_position_float()
		undo_redo.create_action("Set MPF Video Start")
		undo_redo.add_do_property(player, "start_frame", new_start_frame)
		undo_redo.add_do_property(player, "start_position_seconds", new_start_seconds)
		undo_redo.add_undo_property(player, "start_frame", old_start_frame)
		undo_redo.add_undo_property(player, "start_position_seconds", old_start_seconds)
		undo_redo.commit_action()
		player.notify_property_list_changed()
		_refresh()

	func _on_set_end_pressed() -> void:
		if not _prepare_preview_if_possible():
			return
		var undo_redo = editor_plugin.get_undo_redo()
		var old_end_frame: int = player.end_frame
		var old_end_seconds: float = player.end_position_seconds
		var new_end_frame: int = player.current_frame
		var new_end_seconds: float = player.get_current_playback_position_float()
		undo_redo.create_action("Set MPF Video End")
		undo_redo.add_do_property(player, "end_frame", new_end_frame)
		undo_redo.add_do_property(player, "end_position_seconds", new_end_seconds)
		undo_redo.add_undo_property(player, "end_frame", old_end_frame)
		undo_redo.add_undo_property(player, "end_position_seconds", old_end_seconds)
		undo_redo.commit_action()
		player.notify_property_list_changed()
		_refresh()

	func _on_slider_drag_started() -> void:
		_is_scrubbing = true
		if is_instance_valid(player):
			player.pause()

	func _on_slider_drag_ended(value_changed: bool) -> void:
		if value_changed:
			_seek_to_seconds(slider.value)
		_is_scrubbing = false
		_refresh()

	func _on_slider_value_changed(value: float) -> void:
		if _is_scrubbing:
			_seek_to_seconds(value)

func _can_handle(object: Object) -> bool:
	return object != null and object.get_script() == PLAYER_SCRIPT

func _parse_begin(object: Object) -> void:
	add_custom_control(VideoPreviewControls.new(object, host_editor_plugin))
