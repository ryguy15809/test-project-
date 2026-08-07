extends SceneTree

var scene
var frame: int = 0

func _initialize() -> void:
	scene = load("res://node_2d.tscn").instantiate()
	root.add_child(scene)

func _process(_delta: float) -> bool:
	frame += 1
	if frame == 5:
		_capture("C:/Users/catea/AppData/Local/Temp/shot_main.png")
		scene.show_loading_page()
	elif frame == 12:
		_capture("C:/Users/catea/AppData/Local/Temp/shot_loading.png")
		quit()
	return false

func _capture(path: String) -> void:
	var img := root.get_texture().get_image()
	var err := img.save_png(path)
	print("saved ", path, " err=", err, " size=", root.size)