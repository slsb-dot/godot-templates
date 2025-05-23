@tool
extends Control

# TODO: when settings are expanded, and plugin dock width is short, wrapping is weird. fix
# TODO: Add expand all/minimize all buttons
# TODO: Add default texture/tooltip for preview not found
# TODO: If a subpalette has no scenes, don't show it

# TODO: supress warnings
# TODO: Some 2D scenes are not being instantiated for some reason
# TODO: Add favorite groupings
# TODO: Add ability to rearrange favorites
# TODO: Shrink font size on buttons with long names to show more of the name

@export_category("Sub Scenes")
@export var subpalette_scene:PackedScene
@export var scene_drop_scene:PackedScene
@export var fav_button_scene:PackedScene

var top_level_sub_palette:PalettePluginSubPalette

# containers
@onready var favorites_bar = %FavoritesBar
@onready var favorites_settings = %FavoritesSettings
@onready var scroll_container = %ScrollContainer
@onready var scene_scale_setting: HFlowContainer = %SceneScaleSetting

# buttons, etc
@onready var file_dialog = %FileDialog
@onready var choose_directory_button = %ChooseDirectoryButton
@onready var save_dir_to_favorites = %SaveDirToFavorites
@onready var instantiate_for_preview_button = %UsePreviewCheckButton
@onready var icon_scene_scale_slider = %IconSceneScaleSlider
@onready var show_scene_label_button = %ShowSceneLabelButton
@onready var supported_file_type_label: Label = %SupportedFileTypeLabel
@onready var allow_file_types_button: CheckButton = %AllowFileTypesButton
@onready var animation_player: AnimationPlayer = $AnimationPlayer


# have save data to remember favorite palettes
const save_data_dir = "res://addons/scene_palette/save_data/"
const save_data_path = save_data_dir + "save_data.tres"
const pp = 'ScenePalettePlugin: ' # prepended to any printed messages
const allowed_file_types = ['scn', 'tscn', 'png', 'gltf', 'glb', 'fbx', 'obj']

# signals to scene drops to indicate setting changes
signal scene_scale_changed(amt:float)
signal show_scene_label_toggled(toggled_on:bool)

var is_settings_visible:bool
signal setting_visibility_toggled(toggled_on:bool)

var _loading_main_palette:bool = false

var _current_dir:
	set(value):
		# setting button_pressed values below can trigget this function
		# to be called twice in a row, this variable is a quick fix to not allow
		# duplicate calls which in some cases can duplicate scene drop and subpalette instances.
		if _loading_main_palette:
			return
		_loading_main_palette = true

		_current_dir = value
		
		# remove top level palette
		for child in scroll_container.get_children():
			child.queue_free()
		
		# create new top level palette
		top_level_sub_palette = subpalette_scene.instantiate()
		top_level_sub_palette.directory = _current_dir
		scroll_container.add_child(top_level_sub_palette)
		var palette_title = _current_dir.split('/')[-1]
		top_level_sub_palette.set_title(palette_title)
		top_level_sub_palette.expandable = false  # all subpalettes can be minimized, but not the top level
		
		# if we are navigating to a favorite, load saved settings for it
		if _current_dir_in_favorites():
			var save_data:PalettePluginSaveData = _get_save_data()
			_clean_save_data() # clear any stale references to minimized directories
			var favorite = save_data.favorites[_current_dir]
			top_level_sub_palette.set_color(favorite.color)
			instantiate_for_preview_button.button_pressed = favorite.instantiate_scenes_for_previews 
			scene_scale_setting.visible = favorite.instantiate_scenes_for_previews 
			show_scene_label_button.button_pressed = favorite.get('show_labels', false)
			allow_file_types_button.button_pressed = favorite.get('allow_nonscene_files', false)
		else:
			# default settings for new directory
			icon_scene_scale_slider.value = 1
			scene_scale_setting.visible = false
			instantiate_for_preview_button.button_pressed = false
			icon_scene_scale_slider.value = 1
		
		_populate_scenes(top_level_sub_palette, _current_dir)
		show_scene_label_toggled.emit(show_scene_label_button.button_pressed)
		
		# These settings must be loaded after scene drops are populated
		if _current_dir_in_favorites():
			var save_data:PalettePluginSaveData = _get_save_data()
			var favorite = save_data.favorites[_current_dir]
			var flattened_dirs:Dictionary = favorite.get("flattened_dirs", {})
			top_level_sub_palette.subdirs_flattened = _current_dir in flattened_dirs.keys()
			top_level_sub_palette.flatten_changed.connect(_on_sub_palette_flatten_changed.bind(_current_dir))
			icon_scene_scale_slider.value = favorite.get('scene_preview_scale', 1)
			
		await get_tree().create_timer(0.05).timeout # ¯\_(ツ)_/¯ don't work without it, theres def a better way to wait until scene drops are added
		scene_scale_changed.emit(icon_scene_scale_slider.value)  # if value is different from 1, set all of the scene drops to correct scale
		
		_loading_main_palette = false

func _reload_palette():
	_current_dir = _current_dir

## Recursively create subpalettes for the specified directory
func _populate_scenes(sub_palette:PalettePluginSubPalette, dir_path:String):
	var save_data:PalettePluginSaveData = _get_save_data()
	var minimized_dirs:Dictionary
	var flattened_dirs:Dictionary
	
	if _current_dir_in_favorites():
		var favorite = save_data.favorites[_current_dir]
		minimized_dirs = favorite.get("minimized_dirs", {})
		flattened_dirs = favorite.get("flattened_dirs", {})
	else:
		minimized_dirs = {}
		flattened_dirs = {}
	
	var dir = DirAccess.open(dir_path)
	if dir:
		for dir_name in dir.get_directories():
			var new_sub_palette:PalettePluginSubPalette = subpalette_scene.instantiate()
			var path = dir_path + '/' + dir_name
			sub_palette.add_subpalette(new_sub_palette)
			new_sub_palette.directory = path
			new_sub_palette.flatten_changed.connect(_on_sub_palette_flatten_changed.bind(path))
			new_sub_palette.minimized = minimized_dirs.has(path)
			new_sub_palette.minimize_changed.connect(_on_sub_palette_minimize_changed.bind(path))
			new_sub_palette.set_title(dir_name)
			_populate_scenes(new_sub_palette, path)
			new_sub_palette.subdirs_flattened = flattened_dirs.has(path)  # has to be set after sub palettes are populated - this might be a race condition?
		for file_name in dir.get_files():
			var file_extension:String = file_name.split('.')[-1]
			var all_file_types_allowed:bool = allow_file_types_button.button_pressed
			if file_extension == 'tscn' or file_extension == 'scn' or (all_file_types_allowed and file_extension in allowed_file_types):
				var scene_drop:PalettePluginSceneDrop = scene_drop_scene.instantiate()
				sub_palette.add_item(scene_drop)
				scene_drop.instantiate_scene_preview = instantiate_for_preview_button.button_pressed
				scene_scale_changed.connect(scene_drop.adjust_scale)
				show_scene_label_toggled.connect(scene_drop.show_file_label)
				scene_drop.set_scene(dir_path +'/' + file_name)
	else:
		print(pp, 'No directory found for ', dir_path)
	
	setting_visibility_toggled.connect(sub_palette.toggle_flatten_setting_visibility)
	sub_palette.toggle_flatten_setting_visibility(is_settings_visible)  # if settings are currently visible, show toggles


func _ready():
	save_dir_to_favorites.hide()
	scene_scale_setting.hide()

	_populate_favorites_tab_bar()
	if not FileAccess.file_exists(save_data_path):
		_create_new_save_data()
	
	var types_string:String = 'Supported file types: '
	for type in allowed_file_types:
		types_string += type + ', '
	types_string = types_string.left(types_string.length() - 2) # remove last comma
	
	supported_file_type_label.text = types_string

func _create_new_save_data():
	var data = PalettePluginSaveData.new()
	ResourceSaver.save(data, save_data_path)

func _get_save_data() -> PalettePluginSaveData:
	if not FileAccess.file_exists(save_data_path):
		# This only happens if a user manually deletes the save_data while the plugin is enabled
		print(pp, 'favorites data was removed. Creating new save data.')
		_create_new_save_data()
		_populate_favorites_tab_bar()
	return ResourceLoader.load(save_data_path)

func _clean_save_data():
	# Removes stale directory references
	var save_data:PalettePluginSaveData = _get_save_data()
	if _current_dir_in_favorites():
		var favorite:Dictionary = save_data.favorites[_current_dir]
		var minimized_dirs = favorite.get_or_add("minimized_dirs", {})
		var flattened_dirs = favorite.get_or_add("minimized_dirs", {})
		for path in minimized_dirs.keys():
			if not DirAccess.dir_exists_absolute(path):
				save_data.favorites[_current_dir]["minimized_dirs"].erase(path)
		for path in flattened_dirs.keys():
			if not DirAccess.dir_exists_absolute(path):
				save_data.favorites[_current_dir]["flattened_dirs"].erase(path)
		_save_data(save_data)

func _save_data(data:PalettePluginSaveData):
	ResourceSaver.save(data, save_data_path)

func _on_choose_directory_button_pressed():
	file_dialog.show()

func _on_file_dialog_dir_selected(dir):
	_current_dir = dir
	choose_directory_button.text = dir #.split('/')[-1]
	if not _current_dir_in_favorites():
		save_dir_to_favorites.show()
	else:
		save_dir_to_favorites.hide()

func _on_use_preview_check_button_toggled(toggled_on):
	top_level_sub_palette.instantiate_previews(toggled_on)
	if _current_dir_in_favorites():
		var save_data = _get_save_data()
		save_data.favorites[_current_dir].instantiate_scenes_for_previews = toggled_on
		_save_data(save_data)

	scene_scale_setting.visible = toggled_on


## Load favorites buttons
func _populate_favorites_tab_bar():
	var data:PalettePluginSaveData = _get_save_data()
	
	# clear existing buttons
	for child in favorites_bar.get_children():
		# Don't remove the favorites bar header and settings button:
		if child is PalettePluginFavoriteButton:
			child.queue_free()
	
	# add new buttons
	for dir in data.favorites:
		var btn:PalettePluginFavoriteButton = fav_button_scene.instantiate()
		btn.favorite_selected.connect(_on_new_favorite_selected)
		btn.favorite_removed.connect(_on_favorite_removed)
		btn.favorite_color_changed.connect(_on_favorite_color_changed)
		favorites_bar.add_child(btn)
		btn.directory = dir
		btn.set_color(data.favorites[dir].color)
		btn.set_settings_visibility(favorites_settings.button_pressed)

func _on_new_favorite_selected(dir:String):
	_on_file_dialog_dir_selected(dir)

func _on_favorite_removed(dir:String):
	var save_data:PalettePluginSaveData = _get_save_data()
	save_data.favorites.erase(dir)
	_save_data(save_data)
	_populate_favorites_tab_bar()
	
	# show button to add to favorite again if we removed the current dir
	if dir == _current_dir:
		save_dir_to_favorites.show()

func _on_favorite_color_changed(dir:String, color:Color):
	var save_data:PalettePluginSaveData = _get_save_data()
	save_data.favorites[dir].color = color
	_save_data(save_data)
	
	# show real time updates if we're looking at this directory!
	if _current_dir == dir:
		top_level_sub_palette.set_color(color)

func _on_save_dir_to_favorites_pressed():
	var save_data:PalettePluginSaveData = _get_save_data()
	
	if _current_dir_in_favorites():
			print(pp, _current_dir, ' is already in favorites')
	else:
		save_data.add_favorite(_current_dir, instantiate_for_preview_button.button_pressed)
		_save_data(save_data)
		_populate_favorites_tab_bar()
		save_dir_to_favorites.hide()

func _current_dir_in_favorites() -> bool:
	var save_data:PalettePluginSaveData = _get_save_data()
	return _current_dir in save_data.favorites

## toggle visibility of configuration options
func _on_favorites_settings_toggled(toggled_on):
	setting_visibility_toggled.emit(toggled_on)
	is_settings_visible = toggled_on
	for btn in favorites_bar.get_children():
		if btn is PalettePluginFavoriteButton:
			btn.set_settings_visibility(toggled_on)
	if toggled_on:
		animation_player.play('open_settings')
	else:
		animation_player.play_backwards('open_settings')


func _on_show_scene_label_button_toggled(toggled_on):
	show_scene_label_toggled.emit(toggled_on)
	var save_data:PalettePluginSaveData = _get_save_data()
	if _current_dir in save_data.favorites:
		save_data.favorites[_current_dir].show_labels = toggled_on
		_save_data(save_data)

func _on_icon_scene_scale_slider_value_changed(value:float):
	scene_scale_changed.emit(value)
	var save_data:PalettePluginSaveData = _get_save_data()
	if _current_dir in save_data.favorites:
		save_data.favorites[_current_dir].scene_preview_scale = value
		_save_data(save_data)

func _on_reset_scale_button_pressed():
	icon_scene_scale_slider.value = 1

func _on_allow_file_types_button_toggled(toggled_on: bool) -> void:
	var save_data:PalettePluginSaveData = _get_save_data()
	if _current_dir in save_data.favorites:
		save_data.favorites[_current_dir].allow_nonscene_files = toggled_on
		_save_data(save_data)
	_reload_palette()

func _on_sub_palette_minimize_changed(toggled_on: bool, path: String) -> void:
	var save_data:PalettePluginSaveData = _get_save_data()
	if _current_dir in save_data.favorites:
		var minimized_dirs = save_data.favorites[_current_dir].get_or_add("minimized_dirs", {})
		# using dict as hash set
		if toggled_on:
			minimized_dirs[path] = null
		else:
			minimized_dirs.erase(path)
		_save_data(save_data)

func _on_sub_palette_flatten_changed(toggled_on:bool, path: String) -> void:
	var save_data:PalettePluginSaveData = _get_save_data()
	if _current_dir in save_data.favorites:
		var flattened_dirs = save_data.favorites[_current_dir].get_or_add("flattened_dirs", {})
		# using dict as hash set
		if toggled_on:
			flattened_dirs[path] = null
		else:
			flattened_dirs.erase(path)
		_save_data(save_data)
		
	await get_tree().create_timer(0.05).timeout # ¯\_(ツ)_/¯ wait till scene drops are moved
	scene_scale_changed.emit(icon_scene_scale_slider.value)  # set moved scene drops to correct scale
