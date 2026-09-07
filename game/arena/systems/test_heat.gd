extends SceneTree

var _f := 0
func _c(l, a, e) -> void:
	if a == e: print("  PASS  %s" % l)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [l, a, e])

func _initialize() -> void:
	print("HeatStatus lives/elimination tests")
	var tubig = load("res://entities/tubig/tubig.tscn").instantiate()
	root.add_child(tubig)
	var heat = tubig.get_node("HeatStatus")

	_c("starts with 3 lives", heat.lives_left, 3)
	_c("starts NORMAL", heat.state, 0)

	heat.ignite()
	_c("tag 1 spends a life", heat.lives_left, 2)
	_c("tag 1 -> BURNING", heat.state, 1)

	heat.ignite()
	_c("re-tag while burning is a no-op", heat.lives_left, 2)

	heat.cool_fully()
	_c("rescue does NOT refund a life", heat.lives_left, 2)
	_c("rescue -> NORMAL", heat.state, 0)

	heat.ignite()
	_c("tag 2 spends a life", heat.lives_left, 1)
	heat.cool_fully()

	heat.ignite()
	_c("tag 3 spends the last life", heat.lives_left, 0)
	_c("last life goes straight to DEAD", heat.state, 2)
	_c("is_dead", heat.is_dead(), true)

	heat.cool_fully()
	_c("a dead player cannot be rescued", heat.state, 2)
	heat.ignite()
	_c("a dead player cannot be re-tagged", heat.lives_left, 0)

	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d FAILED" % _f)
	quit(1 if _f > 0 else 0)
