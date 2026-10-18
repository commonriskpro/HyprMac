# Plan de Corrección de Bugs de UX y Tareas de Implementación

**Documento:** `docs/UX_BUGS_AND_TASKS.md`  
**Componente:** HyprMac (Core / WindowManager / Animation / Shell / ServerBridge)  
**Estado del Hook de WindowServer:** ACTIVO (`libhyprserver.dylib` inyectado y corriendo en WindowServer PID 188). **No requiere reinyección.**  
**Objetivo:** Eliminar fallas visuales de z-order en el cambio de workspaces (bidireccional 1 <-> 2+) y resolver el delay, la pérdida de márgenes superiores y la ausencia de animación en fullscreen (`Alt + F`).

---

## Índice de Bugs

1. **[BUG-01]** Transición de Workspaces: Ventana enfocada de WS saliente queda flotando por delante del WS entrante (2 -> 1), desfase visual en aparición escalonada (1 -> 2+) y parpadeo de regreso.
2. **[BUG-02]** Delay en Despacho de Atajos (`Alt + F`): Hops asíncronos redundantes y llamadas AX bloqueantes.
3. **[BUG-03]** Fullscreen (`Alt + F`): Violación del margen superior (superposición con `HyprBar`) y salto instantáneo sin animación.
4. **[BUG-04]** Falla Sistémica de Animaciones de Ventanas (`windowsMove`, `fullscreen`, `windowsIn`, `windowsOut`): Enrutamiento atómico hacia `libhyprserver.dylib` vía memoria compartida.

---

## Diagnóstico Detallado y Lista de Tareas

### [BUG-01] Transición de Workspaces: Desaparición no atómica, Z-Order y Flashing

#### Causa Raíz Arquitectónica
1. **Flashing / Regresión:** Al finalizar la animación, el código restauraba las transformaciones (`resetWorkspaceTransforms`) de las ventanas salientes a `alpha = 1.0` inmediatamente antes de que el IPC de Accessibility terminara de moverlas al anchor oculto. Esto causaba que la ventana saliente reapareciera en pantalla con opacidad completa antes de esfumarse.
2. **Aparición Escalonada (1 -> 2+):** Se forzaba activación de foco (`makeKeyWindow` / `app.activate`) de forma prematura antes de iniciar la animación y sin que las ventanas entrantes tuvieran `alpha = 0.0`. Al activarse la app en foco, WindowServer la elevaba por encima de las demás apps entrantes, mostrándola antes que su compañera de workspace.
3. **Persistencia de Ventana Enfocada (2 -> 1):** Las ventanas entrantes se restauraban sin tener el canal alfa en cero a nivel compositor, colisionando con el z-order de la app activa saliente.

#### Solución Arquitectónica
- [x] **Task 1.1:** Establecer las transformaciones iniciales vía `HyprServerBridge.shared.setWorkspaceTransform` **antes** de posicionar las ventanas entrantes (`alpha = 0.0` para entrantes, `alpha = targetOpacity` para salientes).
- [x] **Task 1.2:** Posicionar las ventanas entrantes mientras su opacidad en compositor es 0.0, haciéndolas 100% invisibles durante el posicionamiento físico.
- [x] **Task 1.3:** Ordenar ventanas entrantes sobre las salientes (`orderAbove`) y salientes por debajo (`orderBelow`).
- [x] **Task 1.4:** Al finalizar la animación, aparcar las ventanas salientes fuera de pantalla **sin resetear su opacidad a 1.0** mientras residen en el workspace inactivo.
- [x] **Task 1.5:** Traspasar el foco a la ventana destino (`focusWindow`) exclusivamente al completar la animación, cuando todas las ventanas ya están renderizadas en su lugar.

---

### [BUG-02 & BUG-03] Fullscreen (`Alt + F`): Delay, Margen Superior y Animación

#### Causa Raíz Arquitectónica
1. **Secuestro de Geometría por Tag de SkyLight:** Se invocaba `setWindowTags(windowID, tag0: WindowTags.fullScreen.rawValue)`. Esto provocaba que WindowServer forzara la ventana a pantalla completa nativa de macOS de forma síncrona, ignorando el margen de `HyprBar`, destruyendo el cuadro inicial (`curBounds == fullBounds`) y anulando la interpolación de `animateFullscreen`.
2. **Latencia por Hops Redundantes:** El callback del atajo de teclado en `eventTapCallback` ya despachaba en `DispatchQueue.main.async`. Al envolver el cuerpo en un `runOnMainActor` adicional, se introducía un turno extra de RunLoop antes de iniciar cualquier acción.
3. **Consultas Síncronas AX:** Se llamaba a `WindowDetector.shared.getWindowBounds()` para obtener el marco de inicio, bloqueando el hilo principal con mensajes Mach síncronos hacia la aplicación.

#### Solución Arquitectónica
- [x] **Task 2.1:** Eliminar `setWindowTags(fullScreen)` y `clearWindowTags(fullScreen)`. La gestión de pantalla completa es 100% propiedad del gestor de ventanas HyprMac.
- [x] **Task 2.2:** Eliminar el salto `runOnMainActor` anidado en `KeybindManager.fullscreen()`.
- [x] **Task 2.3:** Utilizar el frame almacenado en `fastFocusedWindow` o `fullscreenWindows[wid]` como punto de partida sin IPC bloqueante.
- [x] **Task 2.4:** Respetar estrictamente `computeTilingBounds()` (que incluye el margen inferior de `HyprBarWindow.shared.barBottomY`) tanto al entrar como al salir de pantalla completa.
- [x] **Task 2.5:** Ejecutar `animateFullscreen` bidireccional (`curBounds -> fullBounds` y `fullBounds -> targetFrame`) mediante transformaciones compuestas en WindowServer.

---

## Verificación y Criterios de Aceptación

1. **Workspace Transitions:**
   - Transición de 2 ventanas a 1 ventana: ambas ventanas del workspace 1 desaparecen simultáneamente; la ventana enfocada no queda visible por delante ni parpadea al final.
   - Transición de 1 ventana a 2+ ventanas: todas las ventanas del nuevo workspace aparecen al unísono, desvaneciéndose juntas sin que una aparezca antes que la otra.
2. **Fullscreen (`Alt + F`):**
   - Respuesta instantánea al presionar la combinación de teclas.
   - La ventana no cubre `HyprBar` en el margen superior de la pantalla.
   - Animación fluida de expansión hacia el área de trabajo y contracción hacia el layout Dwindle.
