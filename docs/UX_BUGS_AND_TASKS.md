# Plan de Corrección de Bugs de UX y Tareas de Implementación

**Documento:** `docs/UX_BUGS_AND_TASKS.md`  
**Componente:** HyprMac (Core / WindowManager / Animation / Shell / ServerBridge)  
**Estado del Hook de WindowServer:** ACTIVO (`libhyprserver.dylib` inyectado y corriendo en WindowServer PID 188).  
**Objetivo:** Eliminar fallas visuales de z-order en el cambio de workspaces y resolver el delay, la pérdida de márgenes superiores y la ausencia sistémica de animaciones en todas las ventanas.

---

## Índice de Bugs

1. **[BUG-01]** Transición de Workspaces: Ventana enfocada de WS saliente queda flotando por delante del WS entrante.
2. **[BUG-02]** Delay en Despacho de Atajos (`Alt + F` y dispatchers): Consultas síncronas por AX y hops redundantes.
3. **[BUG-03]** Fullscreen (`Alt + F`): Violación del margen superior (superposición con `HyprBar`).
4. **[BUG-04]** Falla Sistémica de Animaciones de Ventanas (`windowsMove`, `fullscreen`, `windowsIn`, `windowsOut`): Las transformaciones directas por SkyLight son descartadas por WindowServer; no se enrutaban por `libhyprserver.dylib`.

---

## Diagnóstico Detallado y Lista de Tareas

### [BUG-01] Transición de Workspaces: Desaparición no atómica y fuga de Z-Order

#### Descripción del Problema
Cuando el Workspace 1 contiene 2 ventanas y el Workspace 2 contiene 1 ventana, al alternar de 1 a 2, la ventana que tenía el foco en el Workspace 1 permanece visible por encima de la ventana del Workspace 2 en lugar de desaparecer al unísono con su compañera de workspace.

#### Causa Raíz Arquitectónica
1. **Prioridad de App Activa en WindowServer:** macOS sitúa los surfaces del proceso *frontmost* en una capa visual preferente.
2. **Ocultamiento Secuencial vía Accessibility:** Las ventanas salientes se aparcan en un anchor de 1px fuera de pantalla mediante llamadas secuenciales `AXUIElementSetAttributeValue(elem, kAXPositionAttribute, ...)`. El IPC a la app enfocada puede retrasarse respecto a las demás ventanas.
3. **Inversión de Orden de Visibilidad:** Se restaura la ventana del nuevo workspace antes de haber degradado el z-order (`orderBelow`) de la ventana enfocada anterior, permitiendo que esta tape a la entrante antes de que el foco cambie.

#### Tareas
- [x] **Task 1.1:** *Democión Atómica de Z-Order Previa a la Revelación*
  - En `WorkspaceManager.switchToWorkspace`, ejecutar `SkyLightBridge.shared.orderWindow(wid, op: .orderBelow, relativeTo: 0)` para **todas** las ventanas del workspace saliente *antes* de restaurar o revelar cualquier ventana del workspace entrante.
- [x] **Task 1.2:** *Coordinación del Traspaso de Foco (Focus Handover)*
  - Anticipar la activación del proceso/ventana del nuevo workspace para que WindowServer eleve su layer al mismo tiempo que entra a la pantalla, evitando el desfase visual del app saliente.
- [x] **Task 1.3:** *Optimización del Bloque de Ocultamiento*
  - Agrupar la reubicación de ventanas salientes y verificar que las ventanas del workspace inactivo queden estrictamente congeladas fuera de pantalla sin frames intermedios expuestos.

---

### [BUG-02] Delay en Despacho de Atajos (`Alt + F` y Window Actions)

#### Descripción del Problema
Al presionar un atajo como `Alt + F`, se percibe una pausa notable (latencia) antes de que el sistema reaccione.

#### Causa Raíz Arquitectónica
1. **Llamadas AX Síncronas en el Event Tap:** `KeybindManager.fullscreen()` invoca `WindowDetector.shared.getFocusedWindow()`, que realiza llamadas síncronas por IPC de Accessibility (`AXUIElementCopyAttributeValue`) a la aplicación activa dentro de la captura del evento de teclado.
2. **Doble Despacho Asíncrono a la Cola Principal:** Se ejecuta un salto asíncrono con `runOnMainActor` y dentro del callback en `main.swift` se vuelve a despachar con `DispatchQueue.main.async`.
3. **Retiling Síncrono Previo a la Animación:** Antes de iniciar la transición, se ejecuta `engine.applyToSystem` moviendo las demás ventanas por Accessibility síncrono.

#### Tareas
- [x] **Task 2.1:** *Resolución Rápida de Ventana Enfocada (Fast Focus Lookup)*
  - Utilizar el identificador de ventana en caché (`fastFocusedWindow()`) o el estado local de tracking en lugar de consultar síncronamente por AX en cada pulsación de tecla.
- [x] **Task 2.2:** *Eliminación de Saltos Asíncronos Redundantes*
  - Aplanar el flujo de despacho hacia el `MainActor` para que el evento se procese en un único ciclo de runloop.

---

### [BUG-03] Fullscreen (`Alt + F`): Violación del Margen Superior

#### Descripción del Problema
Al entrar en modo fullscreen, la ventana ignora el margen de la barra superior (`HyprBar`) y se posiciona en las coordenadas superiores absolutas, colisionando o superponiéndose con la interfaz de la barra.

#### Causa Raíz Arquitectónica
- En `Sources/HyprMac/main.swift`, el cálculo de `fullBounds` se hace directamente contra `NSScreen.visibleFrame` (`cgY = primaryHeight - (vis.origin.y + vis.height)`), ignorando `HyprBarWindow.shared.barBottomY` y omitiendo la lógica centralizada de `computeTilingBounds()`.

#### Tareas
- [x] **Task 3.1:** *Unificación Geométrica de Fullscreen con `computeTilingBounds`*
  - Ajustar el cálculo de destino para que fullscreen respete el área útil de la pantalla (excluyendo la barra de estado superior).
- [x] **Task 3.2:** *Soporte de Modo Fullscreen con Márgenes / Gaps*
  - Permitir que el fullscreen respete opcionalmente el padding/gap exterior configurado si el usuario define modo fullscreen dentro de márgenes de trabajo.

---

### [BUG-04] Falla Sistémica de Animaciones de Ventanas (`windowsMove`, `fullscreen`, `windowsIn`, `windowsOut`)

#### Descripción del Problema
**Ninguna animación de ventana individual funciona visualmente.** Las ventanas permanecen estáticas durante la duración de la animación (~0.48s) y luego se teletransportan bruscamente a la posición final vía Accessibility. Solo las transiciones de workspace se animaban porque eran las únicas conectadas a `libhyprserver.dylib`.

#### Causa Raíz Arquitectónica
1. **Restricción de Conexión en SkyLight:** `AnimationEngine.step()` intenta aplicar matrices afines (`CGAffineTransform`) en cada tick mediante `SLSTransactionSetWindowTransform` usando la conexión CGS directa del proceso cliente. En macOS, WindowServer no permite aplicar transformaciones arbitrarias a ventanas pertenecientes a otros procesos sin privilegios de servidor.
2. **Desconexión con el Hook del Servidor:** Aunque `libhyprserver.dylib` está cargado y corriendo en WindowServer (PID 188) y expone `HYPR_CMD_SET_WORKSPACE_TRANSFORM` (capaz de transformar cualquier lista de `CGWindowID`), `AnimationEngine` **solo** lo utilizaba para `activeWorkspaceAnimation`. Para todas las animaciones de ventanas individuales (`activeAnimations`: mover, redimensionar, fullscreen, abrir, cerrar), utilizaba la API local de SkyLight, que el WindowServer rechaza silenciosamente.

#### Tareas
- [x] **Task 4.1:** *Unificación del Pipeline de Animaciones en `AnimationEngine` con `HyprServerBridge`*
  - Conectar el bucle de actualización de `activeAnimations` en `AnimationEngine.step()` con `HyprServerBridge.shared.setWorkspaceTransform` para enviar todas las transformaciones afines de ventanas al hook `libhyprserver.dylib` vía memoria compartida en cada V-Sync.
- [x] **Task 4.2:** *Restablecimiento Atómico de Identidad Post-Animación*
  - Al completar cualquier animación de ventana, resetear la transformación afín a la identidad (`CGAffineTransform.identity`) a través del hook antes de fijar la posición final por Accessibility.
- [x] **Task 4.3:** *Sincronización del Borde (`BorderWindow`)*
  - Garantizar que el overlay del borde activo acompañe la escala y posición de la ventana de forma continua durante todas las animaciones sin desfasarse.

---

## Criterios de Aceptación y Verificación

1. **Test de Conmutación 2 a 1:** Al pasar del Workspace 1 (2 ventanas, 1 enfocada) al Workspace 2 (1 ventana), las 2 ventanas del Workspace 1 desaparecen en el mismo frame visual; en ningún momento la ventana enfocada anterior queda flotando por encima de la ventana del Workspace 2.
2. **Test de Latencia de Atajo:** Al pulsar `Alt + F`, la ventana reacciona inmediatamente (< 16ms, próximo tick de V-Sync).
3. **Test de Margen Superior:** La ventana maximizada deja libre la barra superior (`HyprBar`) sin taparla ni dejar huecos anómalos.
4. **Test de Animación Continua en Todo el Sistema:** Fullscreen (`Alt + F`), movimientos de retiling, apertura y cierre de ventanas se animan de forma visible, fluida y continua a 60/120Hz mediante `libhyprserver.dylib`.

