extends SceneTree

## Instantiates every scene once, headless, to prove the .tscn edits didn't
## break anything structural. Offline, so no players spawn - this is a
## "does it build" check, not a gameplay check.

func _initialize() -> void:
	var scenes := [
		"res://ui/title_screen/title_screen.tscn",
		"res://ui/lobby/lobby.tscn",
		"res://ui/settings/settings.tscn",
		"res://game/arena/actors/tubig/tubig.tscn",
		"res://game/arena/actors/sili/sili.tscn",
		"res://game/arena/arena.tscn",
		"res://maps/boracay_shore/boracay_shore.tscn",
		"res://maps/boracay/boracay.tscn",
	]
	for path in scenes:
		var packed = load(path)
		if packed == null:
			print("  FAIL  could not load %s" % path)
			continue
		var inst = packed.instantiate()
		if inst == null:
			print("  FAIL  could not instantiate %s" % path)
			continue
		root.add_child(inst)
		print("  OK    %s  (%d nodes)" % [path, _count(inst)])
		inst.queue_free()
	print("scene instantiation finished")
	quit()

func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
