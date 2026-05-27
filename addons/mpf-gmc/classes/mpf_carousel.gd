class_name MPFCarousel
extends Control

## Shows and hides child nodes based on the selection of an MPF Carousel mode.
##
## Each child of this Node should have a name matching one of `the selectable_items`
## in the carousel's mode code.
##
## @tutorial: https://missionpinball.org/gmc/reference/mpf-carousel/

## The name of the MPF mode that uses Carousel as its custom mode code.
@export var carousel_name: String
## If true, ask the next carousel child to warm its media after the current child is shown.
@export var preload_next_child: bool = false
@warning_ignore("shadowed_global_identifier")
var log: GMCLogger
var _visible_child: Node = null
var _transition_generation: int = 0


func _enter_tree():
	# Create a log
	self.log = preload("res://addons/mpf-gmc/scripts/log.gd").new("Carousel<%s:%s>" % [self.name, carousel_name])

func _ready():
	for c in self.get_children():
		c.hide()
	if not carousel_name:
		self.log.info("Carousel node does not have a carousel_name property defined. Using '%s' as fallback.", self.name)
		carousel_name = self.name
	if not carousel_name in MPF.game.active_modes and OS.has_feature("debug"):
		self.log.warning("No active mode '%s', carousel will not function until that mode is active.", [carousel_name])
	MPF.server.carousel_item_highlighted.connect(self._on_item_highlighted)
	self.log.debug("Carousel active and waiting for carousel_item_highlighted events for 'carousel=%s'.", carousel_name)

func _on_item_highlighted(payload: Dictionary) -> void:
	if payload.get("carousel") != self.carousel_name:
		self.log.debug("GMC node carousel_name does not match carousel_item_highlighted parameter carousel '%s', ignoring.", payload.get("carousel"))
		return
	self.log.debug("Carousel looking for child matching name '%s'", payload.item)
	var highlighted_index := -1
	var children := self.get_children()
	var highlighted_child: Node = null

	for c in children:
		if c.name == payload.item:
			highlighted_child = c
			highlighted_index = children.find(c)
			break

	if highlighted_child == null:
		self.log.warning("Carousel could not find a child named '%s' to highlight.", payload.item)
		return

	self.log.debug("Showing carousel child '%s'", highlighted_child.name)
	_transition_generation += 1
	var transition_generation := _transition_generation
	var previous_child: Node = _visible_child if _visible_child != highlighted_child and _visible_child != null and _visible_child.visible else null

	highlighted_child.show()
	highlighted_child.move_to_front()
	_visible_child = highlighted_child

	if previous_child != null and _should_wait_for_child_frame(highlighted_child):
		highlighted_child.video_loaded.connect(
			_finish_carousel_transition.bind(highlighted_child, transition_generation),
			CONNECT_ONE_SHOT
		)
	else:
		_hide_non_highlighted(highlighted_child)

	if preload_next_child:
		call_deferred("_preload_next_child", children, highlighted_index)

func _should_wait_for_child_frame(child: Node) -> bool:
	if not child.has_signal("video_loaded"):
		return false
	if child.has_method("is_open") and child.is_open():
		return false
	return true

func _finish_carousel_transition(highlighted_child: Node, transition_generation: int) -> void:
	if transition_generation != _transition_generation:
		return
	_hide_non_highlighted(highlighted_child)

func _hide_non_highlighted(highlighted_child: Node) -> void:
	for c in self.get_children():
		if c != highlighted_child:
			c.hide()

func _preload_next_child(children: Array, highlighted_index: int) -> void:
	if highlighted_index < 0 or children.is_empty():
		return

	var next_index := (highlighted_index + 1) % children.size()
	var next_child: Node = children[next_index]
	if next_child.has_method("preload_video"):
		next_child.preload_video()
