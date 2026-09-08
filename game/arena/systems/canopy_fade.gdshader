shader_type canvas_item;

// Per-canopy fade for the "over" TileMapLayers. See canopy_fade.gd.
//
// modulate is a property of the whole CanvasItem, and a TileMapLayer is one
// CanvasItem - so fading through modulate can only ever fade every tree in the
// layer at once. This masks in the fragment stage instead, which is the only
// way to give individual canopies their own alpha without turning each one
// into a node.
//
// Two mask shapes, because the layers are not all the same shape of problem:
//
//   RECT   - fade everything inside a world-space box. The box is the bounding
//            rect of the connected clump of tiles the player is standing under,
//            worked out by a flood fill in GDScript. Right for a lone palm or a
//            single building roof, where the whole object should lift.
//   RADIAL - fade a soft circle around the player. Right where the canopy is
//            painted as one continuous mass and there is genuinely no "one
//            tree" to isolate.
//
// fade_radius > 0.0 selects RADIAL; otherwise RECT.

// World-space box: xy = top-left corner, zw = size.
uniform vec4 fade_rect = vec4(0.0);

// World-space centre and radius for the circular mask.
uniform vec2 fade_center = vec2(0.0);
uniform float fade_radius = 0.0;

// Alpha under the canopy. Deliberately not 0.0 - keeping it faintly visible
// reads as "you are under something", where clearing it fully just looks like
// the art popped out of existence.
//
// canopy_fade.gd overwrites this on every layer at _ready(); the value here is
// only what a layer would show if the script were detached. Kept in step with
// the script's default so the two can't tell different stories.
uniform float faded_alpha : hint_range(0.0, 1.0) = 0.15;

// Eased 0..1, driven from GDScript so the fade timing stays where it was.
uniform float blend : hint_range(0.0, 1.0) = 0.0;

// Softness of the circular mask's edge, as a fraction of the radius.
uniform float edge_softness : hint_range(0.0, 1.0) = 0.45;

// Layer-local, not global: passing MODEL_MATRIX-transformed positions works
// but depends on how the tilemap quads get batched. VERTEX is already in the
// layer's own space, and GDScript can convert the player's position into that
// same space with to_local(), so both sides agree by construction.
varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	float mask;

	if (fade_radius > 0.0) {
		float d = distance(local_pos, fade_center);
		mask = 1.0 - smoothstep(fade_radius * (1.0 - edge_softness), fade_radius, d);
	} else {
		vec2 lo = fade_rect.xy;
		vec2 hi = fade_rect.xy + fade_rect.zw;
		bool inside = local_pos.x >= lo.x && local_pos.x <= hi.x
		           && local_pos.y >= lo.y && local_pos.y <= hi.y;
		mask = inside ? 1.0 : 0.0;
	}

	COLOR.a *= mix(1.0, faded_alpha, mask * blend);
}
