extends SceneTree

## HeatStatus lives, rescue immunity and elimination.
##
## TIME. _initialize() runs start to finish inside a single call, so no frame
## ever ticks while these assertions run and nothing that decays on a timer
## decays on its own. That matters because a rescue now grants
## RESCUE_IMMUNITY_TIME seconds during which a tag simply does not land (see
## HeatStatus.RESCUE_IMMUNITY_TIME) - an earlier version of this file rescued and
## re-tagged on the next line, and every tag after the first rescue quietly did
## nothing. _advance() drives HeatStatus's own clock by hand instead, standing in
## for the seconds a real player would have spent running away.

var _f := 0
func _c(l, a, e) -> void:
	if a == e: print("  PASS  %s" % l)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [l, a, e])


## Offline, _process() runs its whole body, so this decays rescue immunity and
## the burn timer exactly the way a real frame would.
func _advance(heat, seconds: float) -> void:
	heat._process(seconds)


func _initialize() -> void:
	print("HeatStatus lives/elimination tests")
	var tubig = load("res://game/arena/actors/tubig/tubig.tscn").instantiate()
	root.add_child(tubig)
	var heat = tubig.get_node("HeatStatus")

	_c("starts with 3 lives", heat.lives_left, 3)
	_c("starts NORMAL", heat.state, 0)

	# The return value is what the feed reads: HeatStatus announces a tag only
	# when one actually landed, so a claim the rules refuse has to report false
	# rather than silently doing nothing.
	_c("a tag that lands reports true", heat.ignite(), true)
	_c("tag 1 spends a life", heat.lives_left, 2)
	_c("tag 1 -> BURNING", heat.state, 1)

	_c("re-tag while burning reports false", heat.ignite(), false)
	_c("re-tag while burning is a no-op", heat.lives_left, 2)

	_c("a rescue that frees somebody reports true", heat.cool_fully(), true)
	_c("rescue does NOT refund a life", heat.lives_left, 2)
	_c("rescue -> NORMAL", heat.state, 0)
	_c("rescue grants immunity", heat.is_immune, true)
	_c("rescuing an already-free player reports false", heat.cool_fully(), false)

	# The Sili is usually still standing on the spot the burn had them rooted to,
	# so without this window a rescue and an instant re-tag are the same frame.
	_c("a tag inside the immunity window reports false", heat.ignite(), false)
	_c("a tag inside the immunity window costs no life", heat.lives_left, 2)
	_c("...and leaves them NORMAL", heat.state, 0)

	_advance(heat, heat.RESCUE_IMMUNITY_TIME + 0.1)
	_c("immunity expires", heat.is_immune, false)

	heat.ignite()
	_c("tag 2 spends a life", heat.lives_left, 1)
	heat.cool_fully()
	_advance(heat, heat.RESCUE_IMMUNITY_TIME + 0.1)

	heat.ignite()
	_c("tag 3 spends the last life", heat.lives_left, 0)
	_c("last life goes straight to DEAD", heat.state, 2)
	_c("is_dead", heat.is_dead(), true)

	_c("a dead player cannot be rescued", heat.cool_fully(), false)
	_c("...and stays DEAD", heat.state, 2)
	_c("a dead player cannot be re-tagged", heat.ignite(), false)
	_c("...and loses nothing further", heat.lives_left, 0)

	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d FAILED" % _f)
	quit(1 if _f > 0 else 0)
