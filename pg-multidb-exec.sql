DO $$
DECLARE
    -- =========================================================================
    -- ZONA DE MANDO: CONFIGURACIÓN DE PARÁMETROS OPERATIVOS
    -- =========================================================================
    
    -- v_dbs_to_include: Usa ARRAY['all'] para atacar todo, o especifica ARRAY['db1', 'db2']
    v_dbs_to_include TEXT[] := ARRAY['all'];  
    
    -- v_dbs_to_exclude: Usa ARRAY['none'] para no omitir ninguna, o especifica ARRAY['template0', 'postgres']
    v_dbs_to_exclude TEXT[] := ARRAY['template0', 'postgres']; 

    -- v_query_to_execute: EL PAYLOAD. Coloca aquí el DDL, DML o consulta administrativa a inyectar.
    -- NOTA: Al ser un bloque DO asíncrono vía dblink_exec, no devuelve un "Result Set" visual (como un SELECT tradicional). 
    -- Está diseñado para ejecutar acciones (Ej: CREATE, UPDATE, DROP, GRANT, VACUUM, etc.)
    v_query_to_execute TEXT := $PAYLOAD$
        
        -- [ REEMPLAZA ESTE CÓDIGO CON LA PETICIÓN DEL CLIENTE ]

      GRANT SELECT on ALL TABLES in schema public to "user_test";
        
    $PAYLOAD$;

    -- =========================================================================
    -- VARIABLES DE INFRAESTRUCTURA 
    -- =========================================================================
    v_db             TEXT;
    v_socket         TEXT;
    v_port           TEXT;
    v_conn_str       TEXT;
    v_db_conn_name   TEXT := 'vanguard_omnicanal_conn';
    v_error_msg      TEXT;
    v_created_dblink BOOLEAN := FALSE;
    v_db_actual_excl TEXT; 
BEGIN
    -- 1. Inicializar entorno y verbosidad
    SET client_min_messages = notice;
    RAISE NOTICE '=========================================================================';
    RAISE NOTICE 'INICIANDO MATRIZ DE EJECUCIÓN';
    RAISE NOTICE '=========================================================================';

    -- 2. Gestión dinámica de dblink
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') THEN
        CREATE EXTENSION dblink;
        v_created_dblink := TRUE;
        RAISE NOTICE '>> [ENTORNO] Extensión dblink creada temporalmente para la orquestación.';
    END IF;

    -- 3. Resolver dirección de sockets locales y puerto activo (Hardening de Samuel)
    SELECT replace(setting, ' ', '') INTO v_socket FROM pg_settings WHERE name = 'unix_socket_directories';
    SELECT setting INTO v_port FROM pg_settings WHERE name = 'port';

    -- 4. Iteración con filtrado matricial de Bases de Datos
    FOR v_db IN 
        SELECT datname 
        FROM pg_database 
        WHERE datallowconn = true -- Solo intentar en DBs que aceptan conexiones
            -- Regla de Inclusión
            AND (EXISTS (SELECT 1 FROM unnest(v_dbs_to_include) i WHERE LOWER(i) = 'all') OR datname = ANY(v_dbs_to_include))
            -- Regla de Exclusión
            AND NOT (datname = ANY(v_dbs_to_exclude) AND NOT EXISTS (SELECT 1 FROM unnest(v_dbs_to_exclude) e WHERE LOWER(e) = 'none'))
    LOOP
        -- Construcción del string de conexión local por sockets de confianza
        v_conn_str := format('dbname=%L host=%s port=%s user=postgres', v_db, v_socket, v_port);
        
        BEGIN
            -- Intento de conexión remota
            PERFORM dblink_connect(v_db_conn_name, v_conn_str);
            
            -- Inyección del Payload del Cliente
            PERFORM dblink_exec(v_db_conn_name, v_query_to_execute);
            
            -- Cierre exitoso de sesión remota
            PERFORM dblink_disconnect(v_db_conn_name);
            
            RAISE NOTICE '>> [ÉXITO] Payload ejecutado impecablemente en: %', v_db;
            
        EXCEPTION WHEN OTHERS THEN
            -- Contención de Daños: Captura del error específico de la DB actual
            GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
            RAISE WARNING '>> [ERROR] Fallo de inyección en "%" | Razón: %', v_db, v_error_msg;
            
            -- Frenos de Emergencia (Kill Switch de Lucas): Liberar canal dblink
            IF dblink_get_connections() @> ARRAY[v_db_conn_name] THEN
                PERFORM dblink_disconnect(v_db_conn_name);
            END IF;
        END;
    END LOOP;

    -- 5. Limpieza final de la casa (Zero Residues)
    IF v_created_dblink THEN
        DROP EXTENSION dblink;
        RAISE NOTICE '>> [ENTORNO] Extensión dblink temporal removida. Rastro eliminado.';
    END IF;

    -- =========================================================================
    -- REPORTE FINAL DE BASES DE DATOS EXCLUIDAS (Auditoría Forense)
    -- =========================================================================
    IF NOT EXISTS (SELECT 1 FROM unnest(v_dbs_to_exclude) e WHERE LOWER(e) = 'none') THEN
        RAISE NOTICE '=========================================================================';
        RAISE NOTICE 'DETALLE DE BASES DE DATOS EXCLUIDAS (POR REGLA DE VETO):';
        RAISE NOTICE '=========================================================================';
        
        FOR v_db_actual_excl IN 
            SELECT datname 
            FROM pg_database 
            WHERE 
                (EXISTS (SELECT 1 FROM unnest(v_dbs_to_include) i WHERE LOWER(i) = 'all') OR datname = ANY(v_dbs_to_include))
                AND (datname = ANY(v_dbs_to_exclude))
        LOOP
            RAISE NOTICE '>> [OMITIDA] Base de datos protegida/excluida: %', v_db_actual_excl;
        END LOOP;
    END IF;

    RAISE NOTICE '=========================================================================';
    RAISE NOTICE 'OPERACIÓN COMPLETADA';
    RAISE NOTICE '=========================================================================';

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
    -- Asegurar cierre de dblink ante un colapso estructural masivo
    BEGIN
        PERFORM dblink_disconnect(v_db_conn_name);
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
    RAISE EXCEPTION 'CRÍTICO: Fallo estructural en la matriz de ejecución: %', v_error_msg;
END $$;
