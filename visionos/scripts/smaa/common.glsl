layout(std140, binding = 0) uniform SMAAParams { vec4 rt_metrics; };
#define SMAA_RT_METRICS rt_metrics
#define SMAA_GLSL_4
#define SMAA_PRESET_HIGH
