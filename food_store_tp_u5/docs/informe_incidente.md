# Informe de Incidente — Parte C  
## TP Unidad 5: Simulacro de Ataque y Reconstrucción con IA

---

## 1. Secuencia ejecutada (lo que realmente ocurrió)

El script `simulacro_incidente.sql` ejecutó la siguiente secuencia controlada
contra `foodstore_dev`:

| Paso | Operacion | Resultado esperado | Resultado real |
|---|---|---|---|
| Setup | INSERT cliente victima + fn_resetear_password | Cliente creado con hash bcrypt | OK (tras agregar columna `contrasena_hash`) |
| Fase 1 | 3 llamadas a fn_autenticar con contrasena incorrecta | Retorna NULL (fallo silencioso) | NULL en los 3 intentos |
| Fase 2 | fn_autenticar con contrasena correcta | Retorna id_cliente | Retorno id_cliente = 20004 |
| Fase 3 | SELECT masivo sobre tabla cliente (10 filas) | Datos leidos, sin registro en log | Datos leidos; NO queda en log con `mod` |
| Fase 4 | SET ROLE app_web + GRANT admin_datos TO rol_soporte | Debe fallar con permiso denegado | ERROR: permiso denegado |
| Limpieza | DELETE cliente victima | Dato eliminado | DELETE 1 |

**Nota sobre el incidente previo al simulacro final:** En la primera ejecucion del script,
`GRANT admin_datos TO rol_soporte` se ejecuto sin `SET ROLE app_web` — como `postgres`
(superusuario), el GRANT fue exitoso. Se revirtio inmediatamente con `REVOKE` y se corrigio
el script. Este evento quedo registrado en el log y se documenta como hallazgo: el
superusuario puede escalar cualquier rol; esto es comportamiento esperado de PostgreSQL
y no un defecto del esquema de permisos.

---

## 2. Verificacion del escalamiento (punto 2 de la consigna)

El intento de escalamiento en la ejecucion final **fallo correctamente**:

```
ERROR: se ha denegado el permiso para otorgar el rol «admin_datos»
DETALLE: Solo los roles con la opcion ADMIN en el rol «admin_datos»
         pueden otorgar este rol.
```

El esquema de permisos de la Parte A no tiene defectos en este aspecto.
`app_web` no tiene `CREATEROLE` ni la opcion `ADMIN` sobre `admin_datos`,
por lo que no puede propagar ese rol a ningún otro.

---

## 3. Reconstruccion solicitada a la IA

Se entrego el fragmento `log_simulacro_anonimizado.txt` a Kiro sin contexto adicional,
con la instruccion: *"Analiza este log y reconstrui que ocurrio. Propone una hipotesis
de contencion."*

### Respuesta de la IA (Kiro):

> "El log muestra una sesion de `postgres` sobre `foodstore_dev` que realiza las
> siguientes acciones en secuencia:
>
> 1. Crea un registro de cliente (`INSERT`) e intenta establecer una contrasena
>    mediante `fn_resetear_password`. La funcion falla repetidamente con un error
>    interno (`no existe la columna c.contrasena_hash`), lo que indica que la funcion
>    esta desactualizada o la tabla no tiene la columna esperada.
>
> 2. A continuacion se realizan cuatro llamadas a `fn_autenticar` sobre el mismo mail
>    (`victima01@anon.local`). Las primeras tres fallan con el mismo error interno.
>    La cuarta tambien falla con el mismo error — el log no muestra un inicio de
>    sesion exitoso: todas las llamadas terminan en ERROR.
>
> 3. No hay evidencia en el log de una lectura masiva de datos (SELECT). Si ocurrio,
>    el nivel de auditoria (`log_statement='mod'`) no la capturo.
>
> 4. Se ejecuta `GRANT admin_datos TO rol_soporte`, que falla con permiso denegado.
>    Esto sugiere que el atacante (o el script) intento elevar privilegios de un rol
>    de bajo acceso al rol DBA.
>
> Hipotesis: El incidente parece ser un intento de reconocimiento y escalamiento
> sobre una base de datos con un bug de configuracion (columna faltante). El atacante
> probo credenciales, fallo en autenticar por un error de schema, e intento un
> escalamiento directo de roles que fue bloqueado por el motor.
>
> Contencion sugerida: Corregir el bug de schema (`ALTER TABLE`), auditar si se
> crearon objetos o roles adicionales durante la sesion, y restringir el acceso de
> `postgres` a localhost unicamente."

---

## 4. Contraste: que acerto la IA, que omitio, que afirmo sin evidencia

### Aciertos

- Identifico correctamente la secuencia: INSERT, fn_resetear_password, fn_autenticar x4, GRANT fallido.
- Detecto que el log no muestra el SELECT masivo y explico correctamente por que (`log_statement='mod'`).
- Identifico el intento de escalamiento y que fue bloqueado.
- Recomendo revisar si se crearon objetos adicionales durante la sesion — medida de contencion valida.

### Omisiones

- **No detecto el login exitoso:** La IA afirmo que "todas las llamadas terminan en ERROR", pero el 4to intento (`fn_autenticar` con contrasena correcta) **si retorno el id_cliente**. El log muestra la misma estructura de error porque el error es interno a la funcion (columna faltante), no porque la autenticacion falle logicamente. La IA confundio el error de implementacion con un fallo de autenticacion. En un incidente real, la autenticacion puede haber sido exitosa aunque el log muestre errores de funcion.
- **No identifico la sesion de correccion:** El log incluia una sesion de `ALTER TABLE` y un `REVOKE admin_datos FROM rol_soporte` que la IA no menciono.

### Afirmaciones sin sustento en el log

- La IA afirmo que "el atacante probo credenciales y fallo en autenticar" — esto no esta sustentado. El log muestra errores de funcion, no de autenticacion. No hay forma de saber desde el log si la contrasena era correcta o incorrecta cuando la funcion falla por un error interno.
- La IA caracterizo la sesion como "un atacante" — el log solo muestra al usuario `postgres` (superusuario local). No hay evidencia de acceso externo ni de un tercero.

---

## 5. Decision final de contencion

**Esta decision fue tomada por el equipo a partir de la evidencia del log y del conocimiento
del script ejecutado. No es una accion automatica derivada de la sugerencia de la IA.**

En un caso real, con este patron de log, el equipo tomaria las siguientes acciones:

1. **Corregir el bug de schema inmediatamente:** aplicar `ALTER TABLE cliente ADD COLUMN contrasena_hash TEXT` en produccion (o recrear desde `schema.sql` actualizado). Un error interno en `fn_autenticar` significa que la funcion de seguridad no opera — cualquier llamada falla de forma silenciosa, lo que es peor que un error explicito.

2. **Auditar la sesion de `postgres`:** verificar en el log completo que mas hizo esa sesion antes y despues del fragmento capturado. El usuario `postgres` no deberia ejecutar scripts de aplicacion directamente en produccion.

3. **No bloquear el origen (localhost):** el acceso provino de `::1` (loopback). Bloquear localhost romperia la administracion del servidor. La medida correcta es restringir que usuarios pueden conectarse desde localhost via `pg_hba.conf` — `postgres` deberia requerir autenticacion de certificado o `peer` en produccion, no `scram-sha-256` con contrasena.

4. **Forzar rotacion de contrasena de `app_web` y `admin_datos`:** aunque no hay evidencia de que estas credenciales fueron comprometidas, es practica estandar rotar contrasenas ante cualquier incidente que involucre actividad anomala en la BD.

5. **No escalar a revocacion de roles:** el intento de `GRANT admin_datos TO rol_soporte` fallo. No hay evidencia de que el escalamiento haya tenido exito en ningun momento (el primer GRANT exitoso fue ejecutado por el equipo como error propio y revertido de inmediato). No se justifica una revocacion de emergencia de roles.
