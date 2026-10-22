# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- Forbidden to use greetings, introductions (Sure, I can help you with that...), theoretical explanations, or conclusions. Get straight to the point.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

# VisionQuestPro

App para Apple Vision Pro que ejecuta juegos de Quest a partir de sus ficheros descomprimidos
(APK + carpeta de datos), sin necesitar un Quest. Gráficos con VPKEngine (escojoncio/VPKEngine) y
antialiasing VPKTAA (escojoncio/PTVisionPro).

## Flujo
1. El usuario copia la carpeta de un juego en `QUEST/Juegos` (carpeta elegida con el selector del
   sistema, fuera de la app: no se pierde al reinstalar; mismo concepto que VPS4 en AstroVisionPro).
2. La app detecta los juegos de `QUEST/Juegos`.
3. La primera vez prepara el juego en el propio visor y guarda el resultado en `QUEST/` (caché
   reutilizable, no se repite).
4. El usuario elige juego y juega.

## Launcher
- Tarjeta por juego: nombre, versión, motor (Unity/Unreal/…), API gráfica (Vulkan/GLES), si trae
  variante Quest 3.
- Aviso claro si un juego no es compatible y por qué.
- Registros compartibles desde la app; todo el diagnóstico va al log (no hay Mac para depurar).
- Base visual y estructura: launcher de AstroVisionPro.

## Ajustes (todos dentro de la app, nunca en ficheros de texto)
- Resolución de render.
- VPKTAA en lugar del AA del juego (porcentaje, nitidez).
- Perfil Quest 3 cuando el juego lo tenga.
- ASW desactivable: todos los frames reales, sin extrapolar.
- Nitidez (RCAS): afilado de FSR (RCAS), siempre activo en todos los modos de AA, 0–100 % (global y por juego; 0 = apagado), solo sobre el 3D.
- Foveado: zona nítida, periferia, presets M2 / M5 / personalizado (como PTVisionPro; M5 solo
  seleccionable en un Vision Pro M5).

## Gráficos
- Traductor propio Vulkan/SPIR-V → Metal dentro de VPKEngine, reutilizando su IR (VPIR), emisor MSL,
  backend Metal y grafo de pases. Código 100 % propio (sin MoltenVK, SPIRV-Cross ni Mesa).
- Se quita el MSAA del juego y se aplica VPKTAA.
- Si el juego genera vectores de movimiento (juegos con SpaceWarp), VPKTAA los usa para no dejar
  estelas en objetos en movimiento.
- El foveado del juego se conecta con el foveado propio.
- VPKTAA nativo solo actúa sobre el 3D: la UI/2D dibujada dentro del buffer del ojo (menús, textos, HUD) se
  excluye con una máscara reactiva (R8) que escribe VPKEngine; así el texto no se emborrona.

## Alcance
- Solo juego sin conexión: sin cuentas ni servicios en línea de ningún tipo.
- Partidas guardadas en `QUEST/`.
- Pruebas solo con juegos propios del usuario.
