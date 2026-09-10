# Diseño: glyph `postgresql.db` — credenciales dinámicas de Postgres con declaración mínima

> Estado: **propuesta de diseño** (sin implementar). Objetivo: que una app obtenga una base
> de datos en un cluster CNPG **compartido** y credenciales **dinámicas** de Vault declarando
> en el spell lo mínimo indispensable — idealmente una sola línea.

## 1. Objetivo

Hoy cada app que necesita Postgres:

1. tiene **su propio** cluster CNPG (`keycloak-pg`, `harbor-pg`, …), y
2. recibe un secret **estático** (`vault.secret` con `random: true`) que no rota nunca.

Queremos:

- **Un cluster CNPG compartido** sirviendo varias bases.
- **Credenciales dinámicas** generadas por el secret engine de base de datos de Vault, con TTL
  y rotación automática.
- Que el autor del spell **no toque Vault directamente**: un único glyph `postgresql` con
  `type: db` orquesta todo por debajo.
- Que **la única declaración obligatoria sea `type: db`**; todo lo demás se deriva de
  `common.name` (el nombre de la app) y de la entrada del cluster en el **lexicon**, y es
  sobreescribible.

### Experiencia objetivo del autor del spell

```yaml
# spell de la app — esto es TODO lo necesario para tener DB + creds dinámicas
postgresql:
  miapp:
    type: db
```

De aquí se deriva:

| Derivado | Valor por defecto | Fuente |
|----------|-------------------|--------|
| nombre de la base | `miapp` | `common.name` |
| rol de propietario (owner) estable | `miapp` | `common.name` |
| rol de Vault | `miapp-rw` (read-write) | `common.name` + `role` |
| secret K8s expuesto | `miapp` | `common.name` |
| ServiceAccount / rol Vault K8s-auth | `miapp` | `common.name` (vía `vault.connect`) |
| host / port / mount del engine | de la entrada `type: postgres` del lexicon | lexicon |
| cluster CNPG destino | book default (`labels.default: book`) | lexicon |

---

## 2. Por qué un meta-glyph en `postgresql` (y no usar los de `vault` directo)

Las piezas de Vault que hacen el trabajo **ya existen**:

- `vault.postgresqlDBEngine` (`charts/glyphs/vault/templates/postgresql-db-engine.tpl`) — crea el
  `DatabaseSecretEngineConfig` + roles.
- `vault.secret` con `generationType: database`
  (`charts/glyphs/vault/templates/vault-secret.tpl:107-111`) — crea el `VaultSecret` que
  materializa el K8s Secret con creds efímeras.
- `vault.prolicy` — `Policy` + `KubernetesAuthEngineRole` para que el SA de la app pueda leer
  `database-<book>-<chapter>/creds/*`.

El problema es que **usarlas requiere que el autor del spell entienda Vault**: declarar tres
bloques, conocer la ruta del mount, el nombre del engine, el rol, el formato del secret, etc.
Eso contradice el objetivo de "declaración mínima".

`postgresql.db` es un **meta-glyph** (como ya lo es `postgresql.cluster`): el autor declara
intención (`type: db`) y el glyph compone internamente los recursos de Vault + CNPG con
defaults derivados.

> Nota de arquitectura: el lexicon es de **render-time** — el librarian lo ensambla desde
> `appendix`/`localAppendix` **antes** de renderizar los glyphs. Por eso `postgresql.db`
> **consume** la entrada del cluster vía `runicIndexer`, pero **no puede publicar** una entrada
> que otro spell lea. La publicación de la entrada `type: postgres` del cluster compartido es un
> bloque `appendix.lexicon` que vive en el spell del cluster (§5).

---

## 3. La entrada `type: postgres` del lexicon (schema canónico)

El cluster compartido se publica **una vez**, en el spell que lo define, como entrada de
`appendix.lexicon`. Hoy la única entrada `type: postgres` (`intro/vault.yaml:47`) es
aspiracional y usa campos (`secretName`, `name`, `namespace`) que **no coinciden** con lo que
consume `postgresql-db-engine.tpl` (`host`, `credentialsSecret`). Hay que **estandarizar el schema**.

### 3.1 Principio: declarar solo lo que NO se infiere

Casi todos los campos se derivan de **convenciones CNPG/runik** a partir del nombre de la entrada
y el namespace. El consumidor (`postgresql.db` y el dbEngine embebido) los computa; el productor
solo los declara si los cambia.

| Campo | Inferido de | Default |
|---|---|---|
| `clusterName` | nombre de la entrada (clave del lexicon) | = clave |
| `host` | `<clusterName>-rw.<namespace>.svc` | servicio `-rw` de CNPG |
| `port` | constante | `5432` |
| `credentialsSecret` | convención del cluster glyph | `<clusterName>-superuser` |
| `databaseMount` | contexto book/chapter | `database-<book>-<chapter>` |
| `database` | — | `*` (el engine sirve cualquier DB) |
| `namespace` | convención de despliegue | `databases` (override si el cluster vive en otro ns) |

Lo único que el consumidor **no puede** inferir y conviene marcar es que esta es la entrada por
defecto del book (`labels.default: book`), para que un `type: db` sin selector la encuentre.

### 3.2 Entrada mínima (todo lo demás default)

```yaml
appendix:
  lexicon:
    shared-pg:
      type: postgres
      labels: { default: book }     # ⇐ con esto basta (ns = databases por convención)
```

### 3.3 Entrada completa (solo si cambian los defaults)

```yaml
appendix:
  lexicon:
    shared-pg:
      type: postgres
      namespace: databases                   # override del default
      host: shared-pg-rw.databases.svc       # override (normalmente inferido)
      port: "5432"
      credentialsSecret: shared-pg-superuser
      databaseMount: database-fwck-databases
      clusterName: shared-pg
      # vaultSecretPath: chapter             # alternativa a credentialsSecret (root desde KV)
      labels: { default: book }
```

**Acción de limpieza:** alinear la entrada `vault-pg` existente a este schema o quitarla si no se
usa.

---

## 4. Qué emite `postgresql.db`

Para `type: db` con `common.name = miapp` y la entrada de lexicon `shared-pg`, el glyph
renderiza cuatro recursos (todos opcionales-por-bandera salvo el VaultSecret):

### 4.1 `Database` CNPG — asegura que la base existe en el cluster compartido

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: miapp
spec:
  cluster:
    name: shared-pg            # de lexicon.clusterName
  name: miapp                  # = common.name (override: databaseName)
  owner: miapp                 # rol owner estable (§4.5) (override: owner)
  ensure: present
```

> Requiere CNPG con el CRD `Database` (GA desde el operador 1.25). El chart pinea
> `cloudnative-pg 0.28.2` (operador 1.29.x) → disponible. Verificar en el PoC.

### 4.2 `DatabaseSecretEngineRole` (Vault) — el rol que genera creds efímeras

Una por `role` (`read-write` por defecto; `read-only` opcional). El nombre del rol en Vault es
`<dbname>-rw` / `<dbname>-ro` para que la ruta `creds/` sea estable y única por app:

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: DatabaseSecretEngineRole
metadata:
  name: miapp-rw
spec:
  # authentication/connection vía vault.connect (SA = vault, rol admin del engine)
  path: database-fwck-databases        # databaseMount del lexicon
  dBName: miapp                        # la base concreta (no "*")
  creationStatements:
    - >-
      CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}'
        VALID UNTIL '{{expiration}}' IN ROLE "miapp";
      ALTER ROLE "{{name}}" SET ROLE "miapp";
      GRANT ALL ON SCHEMA public TO "{{name}}";
```

El `IN ROLE "miapp"` + `ALTER ROLE … SET ROLE "miapp"` es la **solución al problema de
propiedad** (§4.5): cada objeto que cree el rol efímero queda *owned* por el rol estable `miapp`,
no por el rol efímero (que expira). Esto reemplaza el `creationStatement` genérico hardcodeado
hoy en `postgresql-db-engine.tpl:88` (que solo hacía `GRANT ALL ON ALL TABLES`, insuficiente con
rotación).

### 4.3 `VaultSecret` — expone las creds como Secret de K8s

Idéntico a lo que hoy genera `vault.secret` con `generationType: database`, pero con todos los
campos derivados:

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: VaultSecret
metadata:
  name: miapp                    # = common.name (override: secretName)
spec:
  refreshPeriod: 30m0s           # override: refreshPeriod
  vaultSecretDefinitions:
    - name: secret
      requestType: GET
      path: database-fwck-databases/creds/miapp-rw
      # authentication/connection vía vault.connect (SA = miapp, rol = miapp)
  output:
    name: miapp
    stringData:
      USERNAME: '{{ .secret.username }}'
      PASSWORD: '{{ .secret.password }}'
      # conveniencia: host/port/dbname inyectados como staticData del lexicon
      HOST: shared-pg-rw.databases.svc
      PORT: "5432"
      DBNAME: miapp
    type: Opaque
```

> El `vault-config-operator` autentica con el SA de la app, pide a Vault una credencial
> efímera del rol `miapp-rw`, y mantiene el Secret sincronizado (rotación cada `refreshPeriod`).

### 4.4 `Policy` + `KubernetesAuthEngineRole` (Vault) — acceso del SA a las creds

Opcional (`policy: true` por defecto), scoped al mínimo:

```yaml
# Policy
path "database-fwck-databases/creds/miapp-*" { capabilities = ["read"] }
# KubernetesAuthEngineRole: SA miapp (namespace de la app) → rol miapp
```

Si la app ya declara `vault.prolicy` (que concede `database-<book>-<chapter>/creds/*`), este
recurso se puede desactivar con `policy: false` para no duplicar.

### 4.5 El rol owner estable `miapp` (la decisión central)

El `Database` CRD (§4.1) exige que `spec.owner` **ya exista** como rol. CNPG solo gestiona roles
de forma declarativa en `Cluster.spec.managed.roles` (a nivel cluster, no por-app), y el lexicon
es lookup, **no agrega listas** entre spells — así que el glyph por-app **no puede** inyectar el
owner en el spec del cluster compartido.

Tres estrategias para crear `miapp` (NOLOGIN, owner de la base). El doc recomienda la **C**:

- **A — `managed.roles` en el spell del cluster.** El cluster compartido lista los owners
  (`miapp`, `otraapp`, …). Simple y declarativo, pero **acopla**: agregar una app obliga a editar
  el spell del cluster. Rompe "app self-contained".
- **B — Job idempotente por app.** El glyph emite un `Job` que con el superuser hace
  `CREATE ROLE … IF NOT EXISTS`-equivalente + `ALTER DATABASE … OWNER TO`. Self-contained, pero
  introduce un Job imperativo (anti-patrón respecto a "todo declarativo").
- **C — (recomendada) el rol efímero crea el owner perezosamente.** El `creationStatement` del
  `DatabaseSecretEngineRole` se hace **idempotente** y crea el owner si falta antes de auto-
  asignárselo:

  ```sql
  DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'miapp') THEN
      CREATE ROLE "miapp" NOLOGIN;
    END IF;
  END $$;
  CREATE ROLE "{{name}}" LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE "miapp";
  ALTER ROLE "{{name}}" SET ROLE "miapp";
  ```

  Y el `Database` CRD (§4.1) crea la base; tras el primer `creds`, se transfiere ownership
  (`ALTER DATABASE miapp OWNER TO miapp` puede ir en el `creationStatement` o en un init del
  cluster). **Ventaja:** completamente self-contained, declarativo, sin Jobs. **A validar en
  PoC:** que el superuser del engine tenga privilegio para `CREATE ROLE`, y el orden
  Database-CRD vs primer `creds`.

> Esta es la única pieza con riesgo real de implementación y el motivo principal de hacer un PoC
> antes de migrar apps.

---

## 5. `type: cluster` embebe su propia config de Vault

### 5.1 Estado actual (validado en `_cluster.tpl`)

Hoy el meta-glyph `postgresql.cluster` **NO** genera nada de Vault. Compone solo:

1. `s3.bucket.impl` — bucket de backup + creds (si no hay `s3SecretRef`).
2. `postgresql.objectStore` — ObjectStore CR (Barman).
3. `postgresql.instance` — el `Cluster` CRD.
4. `postgresql.scheduledBackup` — cron diario.

`superuserSecret` y `secret` son **solo nombres** que el `Cluster` CRD referencia; el Secret en sí
debe existir. Por eso cada spell real declara aparte un `vault.secret … random: true`
(p.ej. `forgejo-pg-superuser`). Es decir: la config de Vault del cluster está **dispersa y
duplicada** en cada spell.

### 5.2 Cambio propuesto — `type: cluster` trae su Vault embebido (menos prolicy)

`postgresql.cluster` pasa a emitir **además**:

- **El secret de superuser** (`RandomSecret` + `VaultSecret` → Secret `<cluster>-superuser`),
  en vez de exigir que el spell lo declare. Mismo patrón que hoy hace a mano cada app.
- **El `DatabaseSecretEngineConfig`** (el "dbEngine"), con `allowedRoles: ["*"]`, **auto-
  referenciando su propio host y su propio superuser secret** (no necesita lexicon: el cluster
  conoce su `<cluster>-rw.<ns>.svc` y el secret que acaba de crear).

**NO** emite `prolicy` — eso es por-workload y vive en el spell de cada app que lo necesite.

Así la definición del cluster sigue existiendo y siendo válida (misma superficie), pero ahora
es **autocontenida**: declarar el cluster deja listo el engine para que `type: db` lo consuma.

### 5.3 El spell del cluster compartido queda (se escribe una vez)

Defaults que ya aplican (validados en `_instance.tpl`): `instances: 1`, `storage.size: 1Gi`,
`backup` enabled+90d, `enableSuperuserAccess: true`. Un cluster compartido **no** lleva
`dbName`/`userName`/`secret` (las bases las crea `type: db`, no el bootstrap initdb).

```yaml
# the-yaml-life/bookrack/fwck/databases/shared-pg.yaml
name: shared-pg
namespace: databases

# Cluster + superuser + dbEngine. El engine es DEFAULT-ON: como hay un
# secret-store en el lexicon, se genera solo (sin flag). Sin vault → se omite.
postgresql:
  shared-pg:
    type: cluster
    instances: 3
    storage: { size: 50Gi }

# Único bloque manual (lexicon = render-time, §2). Mínimo por inferencia (§3.2).
appendix:
  lexicon:
    shared-pg:
      type: postgres
      labels: { default: book }
```

Versión sin overrides de nada (acepta 1 instancia / 1Gi): el bloque `postgresql` se reduce a
`shared-pg: { type: cluster }`.

> Por qué la entrada de lexicon sigue siendo manual: el librarian ensambla el lexicon desde
> `appendix` **antes** de renderizar glyphs, así que `postgresql.cluster` no puede publicarla. Es
> el único bloque que queda fuera del glyph (2 líneas, una vez por cluster).

---

## 6. Cambios en glyphs (Layer 2) — engine GENÉRICO en vault, consumido por postgres

La pieza central: el secret engine de base de datos **es genérico** (las CRDs
`DatabaseSecretEngineConfig`/`DatabaseSecretEngineRole` solo cambian `pluginName`, la cadena de
conexión y los `creationStatements`). Vive en el chart `vault`; postgres (y mañana mongo) lo
consumen aportando esos tres datos.

1. **Nuevo glyph genérico `vault.databaseEngine` + `vault.databaseRole`**
   (`charts/glyphs/vault/templates/database-engine.tpl`). Engine-agnósticos: el templating
   universal `{{username}}/{{password}}` vive ahí; el consumidor solo pasa `connectionPrefix`
   (esquema/host) + `connectionSuffix` (db/params) — o un `connectionURL` completo — y, para el
   role, la lista de `creationStatements`. Autentican como admin de Vault y caen en el namespace
   del servidor Vault (override `configNamespace`).
2. **`postgresql.cluster` CONSUME el genérico — DEFAULT-ON gateado por Vault.** Si hay un
   `type: secret-store` en el lexicon, el cluster genera su superuser secret (salvo que
   `dbEngine.credentialsSecret` apunte a uno existente) y llama a `vault.databaseEngine`
   (`pluginName: postgresql-database-plugin` + prefix/suffix de Postgres) **sin necesidad de
   flag**. **Si no hay Vault en el lexicon, no emite nada de Vault y no falla** (todo anda sin
   Vault). Opt-out explícito: `dbEngine: { enabled: false }`. El bloque `dbEngine:` (opcional)
   solo lleva overrides (`allowedRoles`, `credentialsSecret`, `database`, `configNamespace`, …).
3. **`postgresql.db` CONSUME el genérico.** Construye los `creationStatements` con el patrón
   owner-estable (`IN ROLE` + `SET ROLE` + creación perezosa del owner) y llama a
   `vault.databaseRole`; expone las creds con `vault.secret`. No emite prolicy.
4. **Mongo (futuro)** reusa los mismos `vault.databaseEngine`/`vault.databaseRole`: un
   `mongodb.cluster`/`mongodb.db` aportaría `mongodb-database-plugin`, su connection string y sus
   creationStatements JSON. Cero YAML de Vault duplicado.
5. **`vault.postgresqlDBEngine`** (postgres-específico, solo en ejemplos) queda **obsoleto** a
   favor del par genérico. Dejar por compat o quitar.
6. **Schema lexicon `type: postgres`** — documentar el schema canónico (§3) en
   `docs/usage/lexicon.md` y arreglar la entrada `vault-pg`.

Ninguno toca `talos-chart` ni Layer 1.

---

## 7. Plan de migración (Layer 3 — "migrar la mayoría")

Orden sugerido, de menor a mayor riesgo:

1. **PoC**: desplegar `shared-pg` + 1 app nueva no-crítica con `postgresql.db: { type: db }`.
   Validar: el `Database` CRD crea la base, el owner estable se crea, las creds rotan, la app
   reconecta limpio y los objetos quedan *owned* por el rol estable tras una rotación forzada.
2. **Apps que reconectan limpio** (pools que reabren conexión): migrar de secret estático →
   `type: db`. Candidatas: outline, vikunja, penpot, grafana, forgejo, netbird, las del
   agent-stack (mem0, dim0-backend, interface-api, kestra).
3. **Dejar en cluster dedicado + secret estático** (no toleran rotación / esperan owner fijo):
   - **vault-pg** — Vault es el que provee las creds; dependencia circular.
   - **keycloak**, **harbor** — esperan un owner fijo y/o no reconectan bien.
   - **matrix/synapse** — pool de larga vida, sensible a cortes.
   - **seaweedfs-pg** — ya tiene DR especial a S3 externo (prorator); no tocar.
   Revisar caso por caso en el PoC; la lista es punto de partida, no definitiva.

Criterio de decisión por app: **¿la app reabre conexiones tras un fallo de auth?** Si sí →
candidata a dinámico. Si mantiene un pool fijo de por vida → dejar estático.

---

## 7b. Estado de implementación (testeado por render)

Implementado y validado con `make render glyph postgresql {db,shared-cluster}` +
no-regresión byte-a-byte de los 7 ejemplos previos. Archivos (canónicos en `charts/glyphs/`):

- `vault/templates/database-engine.tpl` — **glyphs genéricos** `vault.databaseEngine` +
  `vault.databaseRole` (engine-agnósticos, reusables para mongo).
- `postgresql/templates/_db-helpers.tpl` — `postgresql.resolveLexicon` (inferencia §3.1).
- `postgresql/templates/_db.tpl` — glyph `postgresql.db` (consumidor; usa `vault.databaseRole`).
- `postgresql/templates/_cluster.tpl` — bloque `dbEngine:` (productor; usa `vault.databaseEngine`).
- Ejemplos: `postgresql/examples/{db,shared-cluster}.yaml`.

Decisiones tomadas al implementar:

1. **El engine es un glyph genérico de `vault`, consumido por postgres — DEFAULT-ON gateado por
   Vault.** Si hay un `secret-store` en el lexicon, `postgresql.cluster` genera el superuser
   (`RandomSecret`+`VaultSecret`→`<cluster>-superuser`) y llama a `vault.databaseEngine`
   (`pluginName` + prefix/suffix de Postgres) sin flag. **Sin Vault en el lexicon: no emite nada
   de Vault y no falla** (validado: cluster→solo `Cluster`). Opt-out: `dbEngine: {enabled:false}`.
   Los ejemplos sin secret-store quedan byte-idénticos; meta-backup/meta-restore (que sí tienen
   vault, por el bucket S3) llevan el opt-out para mantenerse idénticos. El mismo par genérico
   sirve para mongo.
2. **`postgresql.db` NO emite Policy/KubernetesAuthEngineRole.** El `vault.prolicy` del app ya
   concede `database-<book>-<chapter>/creds/*` cuando hay un `type: postgres` en el lexicon
   (`vault-prolicy.tpl:107-117`). Emitir uno duplicaría el `KubernetesAuthEngineRole` del SA.
   ⇒ el app consumidor debe declarar `vault: { prolicy: { type: prolicy } }`.
3. **CRDs de config de Vault (engine + role) van al namespace del servidor Vault**
   (`$vaultConf.namespace`, override `configNamespace`) y autentican como admin
   (`vault.connect … "force"` ⇒ role/SA `vault`). El `Database` CNPG va al namespace del cluster;
   el `VaultSecret` (y su Secret de salida) al namespace del app.
4. **El Secret expuesto lleva `USERNAME`/`PASSWORD` (dinámicos) + `HOST`/`DBNAME`** (conveniencia,
   strings). `PORT` se omite (numérico rompería `stringData`; es 5432 universal).

Pendiente para el PoC en cluster real (no verificable por render):

- Que el `vault-config-operator` pueda autenticar los CRDs de config en el ns de Vault (binding
  del role admin) — IAM de covenant.
- El **orden** `Database` CRD ↔ creación perezosa del owner role (§4.5 estrategia C): si CNPG exige
  el owner antes de que Vault lo cree, sembrar el owner por `managed.roles` o ajustar.
- Sincronizar el submódulo `glyphs` y bumpear los mirrors (`kaster`/`summon`/`covenant`) — el
  testeo local copió los `.tpl` al mirror de `kaster` para renderizar.

## 8. Resumen

- El autor del spell escribe `postgresql: { miapp: { type: db } }` y nada más.
- `postgresql.db` deriva db/owner/rol/secret/SA de `common.name`, y host/port/mount/cluster de la
  entrada `type: postgres` del lexicon (book default).
- Internamente emite: `Database` CNPG + `DatabaseSecretEngineRole` (con patrón owner-estable) +
  `VaultSecret` + (opcional) `Policy`/`KubernetesAuthEngineRole`.
- El cluster compartido y su entrada de lexicon se declaran **una vez**.
- La única incógnita real es la creación del rol owner estable (§4.5, estrategia C recomendada),
  a validar en PoC antes de migrar apps.
```
