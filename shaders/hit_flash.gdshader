shader_type canvas_item;

uniform float flash_intensity : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	COLOR = mix(col, vec4(1.0, 1.0, 1.0, col.a), flash_intensity);
}
