# **SPEC_U6 — Plan de Mantenimiento y Respaldo | Food Store**

### 1. Objetivo del Plan de Mantenimiento

Garantizar la disponibilidad, integridad y recuperabilidad de la base de datos `foodstore` (PostgreSQL 17) mediante tareas automatizadas de respaldo, monitoreo de salud, mantenimiento de estadísticas y validación periódica de restauración. Todas las tareas se ejecutan con el rol `admin_datos` (DB Owner). Las credenciales se resuelven exclusivamente desde `%APPDATA%\postgresql\pgpass.conf`; queda prohibido hardcodearlas en cualquier script. La base `foodstore` nunca recibe operaciones destructivas; las pruebas de restauración se realizan sobre la base descartable `foodstore_restore_test`.

> **Aclaración sobre el Entorno de Pruebas y Horarios:**
> - **Horarios:** Las horas indicadas en la tabla corresponden a la planificación teórica de ventana nocturna en producción. En este entorno de laboratorio, la ejecución y generación de logs/evidencias se realiza a demanda de forma manual a través de la CLI de VS Code/PowerShell.
> - **Carga de Datos:** Al ser un entorno de desarrollo sin tráfico concurrente real de clientes, la base es inmutable salvo por las inserciones/modificaciones manuales ejecutadas durante las pruebas, lo cual se refleja en las lecturas de `pg_stat_user_tables`.

### 2. Tabla de Tareas Programadas y Evidencias

| # | Tarea | Frecuencia | Script | Acción | Criterio de Éxito |
|---|---|---|---|---|---|
| 1 | Respaldo lógico | Diario 02:00 | `backup_foodstore.ps1` | `pg_dump -Fc -Z 6` sobre `foodstore` | Archivo `foodstore_YYYYMMDD_HHMM.dump` generado; `pg_restore --list` sin errores; hash SHA-256 vía `Get-FileHash`; retención 14 días; log con `$LASTEXITCODE -eq 0` |
| 2 | Chequeo de salud | Diario 03:00 | `health_check.sql` vía `psql` | Consulta `pg_stat_activity`, `pg_stat_database`, `pg_stat_user_tables` | Log fechado con métricas de conexiones, tamaño de BD, sesiones bloqueadas y transacciones activas; sin errores de ejecución |
| 3 | Revisión de mantenimiento | Semanal Dom 03:30 | `maintenance.sql` vía `psql` | Inspecciona tuplas muertas; revisa historial de autovacuum; ejecuta `ANALYZE` sobre `pedido`, `detalle_pedido`, `producto` | Log con estado de tablas y `last_analyze` actualizado en `pg_stat_user_tables` para las tres tablas objetivo |
| 4 | Restauración de prueba | Semanal Dom 06:00 | `restore_test.ps1` | Recrea `foodstore_restore_test`; restaura el último `.dump` válido con `pg_restore` | Conteos `COUNT(*)` coinciden con `foodstore`; integridad referencial verificada; RTO registrado; base descartable eliminada al finalizar |


### 3. Criterios de Aceptación y Reglas de Seguridad en PowerShell

- **Verificación de `$LASTEXITCODE`:** cada script `.ps1` evalúa `$LASTEXITCODE` inmediatamente después de invocar `pg_dump`, `pg_restore` o `psql`. Si el valor es distinto de `0`, el script aborta, registra el error en el log y sale con código no cero.
- **Sin credenciales en código:** las contraseñas se resuelven únicamente vía `pgpass.conf`. Ningún script contendrá literales de contraseña ni variables de entorno con credenciales en texto plano.
- **Prohibición sobre `foodstore`:** `DROP DATABASE foodstore`, `TRUNCATE` y `DELETE` sin `WHERE` sobre la base principal están estrictamente prohibidos. Toda operación destructiva se ejecuta exclusivamente sobre `foodstore_restore_test`.
- **Integridad del respaldo:** todo `.dump` debe pasar `pg_restore --list` antes de considerarse válido. Un archivo que no supere esa prueba no cuenta como respaldo del día.
- **Retención automática:** el script de respaldo elimina archivos con más de 14 días vía `Get-ChildItem | Where-Object | Remove-Item`. Cada eliminación queda registrada en el log.

### 4. Casos de Prueba Obligatorios para la Bitácora

| ID | Descripción | Resultado esperado |
|---|---|---|
| CP-01 | Ejecutar `backup_foodstore.ps1` manualmente | `.dump` presente; `pg_restore --list` sin errores; hash SHA-256 registrado en log |
| CP-02 | Simular falla de `pg_dump` (apuntar a BD inexistente) | Script aborta; `$LASTEXITCODE != 0` registrado; no se genera archivo corrupto |
| CP-03 | Ejecutar `health_check.sql` y verificar salida | Log fechado con valores de `pg_stat_database`; sin errores de conexión |
| CP-04 | Ejecutar `maintenance.sql` y verificar estadísticas | `last_analyze` actualizado en `pg_stat_user_tables` para las tres tablas objetivo |
| CP-05 | Ejecutar `restore_test.ps1` con el último `.dump` válido | `foodstore_restore_test` creada; conteos coinciden; RTO registrado; base eliminada al final |
| CP-06 | Verificar resolución de credenciales vía `pgpass.conf` | `psql` y `pg_dump` completan sin prompt interactivo de contraseña |