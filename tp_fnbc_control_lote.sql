/*
=============================================================================
EJERCICIO FNBC -- CONTROL DE LOTE EN ALMACÉN
Archivo : tp_fnbc_control_lote.sql
Motor   : PostgreSQL 17
Base    : foodstore_dev
Autora  : Agustina Micaela Guzmán
=============================================================================
*/

BEGIN;

-- ============================================================
-- PASO 0.A -- DOMINIOS REUTILIZABLES
-- ============================================================

DROP DOMAIN IF EXISTS codigo_producto_dom CASCADE;
CREATE DOMAIN codigo_producto_dom AS VARCHAR(50)
    CONSTRAINT ck_codigo_producto_formato
        CHECK (VALUE ~ '^[A-Z0-9][A-Z0-9\-]{1,48}[A-Z0-9]$');

DROP DOMAIN IF EXISTS dni_arg_dom CASCADE;
CREATE DOMAIN dni_arg_dom AS VARCHAR(20)
    CONSTRAINT ck_dni_arg_formato
        CHECK (VALUE ~ '^\d{7,8}$');


-- ============================================================
-- PASO 0.B -- TABLAS MAESTRAS PREVIAS
-- ============================================================

CREATE TABLE IF NOT EXISTS deposito (
    id        BIGINT        PRIMARY KEY,
    nombre    VARCHAR(100)  NOT NULL,
    ubicacion VARCHAR(255)  NOT NULL,
    capacidad INT           NOT NULL
        CONSTRAINT chk_deposito_capacidad CHECK (capacidad > 0)
);

-- Las fechas de vencimiento deben ser >= CURRENT_DATE
CREATE TABLE IF NOT EXISTS lote (
    id                 BIGINT                PRIMARY KEY,
    codigo_producto    codigo_producto_dom   NOT NULL,
    fecha_vencimiento  DATE                  NOT NULL
        CONSTRAINT chk_lote_vencimiento CHECK (fecha_vencimiento >= CURRENT_DATE)
);

CREATE TABLE IF NOT EXISTS responsable_control (
    id              BIGINT        PRIMARY KEY,
    dni             dni_arg_dom   NOT NULL UNIQUE,
    mail            VARCHAR(100)  NOT NULL
        CONSTRAINT chk_responsable_mail
            CHECK (mail ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    nombre_completo VARCHAR(150)  NOT NULL
);


-- ============================================================
-- PASO 0.C -- DATOS MAESTROS DE PRUEBA
-- ============================================================

INSERT INTO deposito (id, nombre, ubicacion, capacidad)
VALUES
    (30, 'Deposito Central', 'Mendoza',    10000),
    (31, 'Deposito Sur',     'San Martin',  5000)
ON CONFLICT (id) DO NOTHING;

-- Fechas en 2027 para superar chk_lote_vencimiento en 2026
INSERT INTO lote (id, codigo_producto, fecha_vencimiento)
VALUES
    (501, 'PROD-01', '2027-12-31'),
    (502, 'PROD-02', '2027-11-15'),
    (503, 'PROD-03', '2027-10-20')
ON CONFLICT (id) DO NOTHING;

INSERT INTO responsable_control (id, dni, mail, nombre_completo)
VALUES
    (801, '30111222', 'carlos@foodstore.com', 'Carlos Gomez'),
    (802, '32333444', 'ana@foodstore.com',    'Ana Lopez')
ON CONFLICT (id) DO NOTHING;


-- ============================================================
-- PASO 1 -- ESQUEMA ORIGINAL DEFECTUOSO (PRE-FNBC)
-- ============================================================

CREATE TABLE IF NOT EXISTS control_lote_almacen (
    lote_id                 BIGINT  NOT NULL
        REFERENCES lote(id),
    deposito_id             BIGINT  NOT NULL
        REFERENCES deposito(id),
    responsable_control_id  BIGINT  NOT NULL
        REFERENCES responsable_control(id),
    PRIMARY KEY (lote_id, deposito_id)
);

INSERT INTO control_lote_almacen
    (lote_id, deposito_id, responsable_control_id)
VALUES
    (501, 30, 801),
    (502, 30, 801),
    (503, 31, 802)
ON CONFLICT DO NOTHING;


-- ============================================================
-- PASO 2 -- DESCOMPOSICIÓN EN FNBC
--   R1 = pi{R,D}  -->  responsable_deposito
--   R2 = pi{L,R}  -->  control_lote_responsable
-- ============================================================

-- R1: aísla la DF problemática (responsable -> depósito)
CREATE TABLE IF NOT EXISTS responsable_deposito (
    responsable_control_id  BIGINT  PRIMARY KEY
        REFERENCES responsable_control(id),
    deposito_id             BIGINT  NOT NULL
        REFERENCES deposito(id)
);

-- R2: vínculo lote-responsable
CREATE TABLE IF NOT EXISTS control_lote_responsable (
    lote_id                 BIGINT  NOT NULL
        REFERENCES lote(id),
    responsable_control_id  BIGINT  NOT NULL
        REFERENCES responsable_deposito(responsable_control_id),
    PRIMARY KEY (lote_id, responsable_control_id)
);


-- ============================================================
-- PASO 3 -- VISTA DE COMPATIBILIDAD
-- Reconstituye (L, D, R) vía reunión natural de R1 y R2.
-- ============================================================

CREATE OR REPLACE VIEW vw_control_lote_almacen_compatibilidad AS
SELECT
    clr.lote_id,
    rd.deposito_id,
    clr.responsable_control_id
FROM control_lote_responsable  clr
JOIN responsable_deposito       rd
    ON clr.responsable_control_id = rd.responsable_control_id;


-- ============================================================
-- PASO 4 -- MIGRACIÓN DE DATOS A LAS TABLAS FNBC
-- ============================================================

-- R1: DISTINCT colapsa duplicados del mismo responsable/depósito
INSERT INTO responsable_deposito
    (responsable_control_id, deposito_id)
SELECT DISTINCT
    responsable_control_id,
    deposito_id
FROM control_lote_almacen
ON CONFLICT DO NOTHING;

-- R2: el par (lote, responsable) es único en la instancia original
INSERT INTO control_lote_responsable
    (lote_id, responsable_control_id)
SELECT
    lote_id,
    responsable_control_id
FROM control_lote_almacen
ON CONFLICT DO NOTHING;


-- ============================================================
-- PASO 5 -- VERIFICACIÓN LOSSLESS-JOIN (EXCEPT en ambas dir.)
-- Resultado esperado: 0 filas en cada query.
-- ============================================================

-- Dirección A: tuplas espurias (vista EXCEPT original)
-- 'Espurias' -> Información falsa generada por un JOIN mal diseñado. Deja lugar a pérdidas de información. 
SELECT * FROM (
    SELECT lote_id, deposito_id, responsable_control_id
    FROM vw_control_lote_almacen_compatibilidad
    EXCEPT
    SELECT lote_id, deposito_id, responsable_control_id
    FROM control_lote_almacen
) dir_a;

-- Dirección B: pérdida de datos (original EXCEPT vista)
SELECT * FROM (
    SELECT lote_id, deposito_id, responsable_control_id
    FROM control_lote_almacen
    EXCEPT
    SELECT lote_id, deposito_id, responsable_control_id
    FROM vw_control_lote_almacen_compatibilidad
) dir_b;

COMMIT;


-- ============================================================
-- PARTE 2 -- EXPLAIN ANALYZE: top 5 categorías del día
-- ============================================================

EXPLAIN ANALYZE
SELECT c.nombre AS categoria,
       SUM(dp.cantidad * dp.precio_unitario_historico) AS total_vendido
FROM detalle_pedido dp
JOIN producto pr  ON pr.id_producto = dp.id_producto
JOIN categoria c  ON c.id_categoria = pr.id_categoria
JOIN pedido ped   ON ped.id_pedido  = dp.id_pedido
WHERE DATE(ped.fecha_hora) = CURRENT_DATE
GROUP BY c.nombre
ORDER BY total_vendido DESC
LIMIT 5;


-- ============================================================
-- LIMPIEZA (ejecutar manualmente si es necesario)
-- ============================================================

-- ROLLBACK;
-- DROP VIEW  IF EXISTS vw_control_lote_almacen_compatibilidad;
-- DROP TABLE IF EXISTS control_lote_responsable;
-- DROP TABLE IF EXISTS responsable_deposito;
-- DROP TABLE IF EXISTS control_lote_almacen;
-- DROP TABLE IF EXISTS responsable_control;
-- DROP TABLE IF EXISTS lote;
-- DROP TABLE IF EXISTS deposito;
-- DROP DOMAIN IF EXISTS codigo_producto_dom;
-- DROP DOMAIN IF EXISTS dni_arg_dom;
